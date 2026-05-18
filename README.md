# warp-masque

English | [日本語](README.ja.md)

Cloudflare WARP as a SOCKS5/HTTP proxy (or TUN gateway), spoken over **MASQUE/HTTP/3** — the same protocol Cloudflare's 1.1.1.1 mobile app uses. Drops in where WireGuard-based wrappers get blocked by UDP/DPI filters, with an HTTP/2-over-TLS fallback when QUIC is unreachable. An opt-in pool mode runs N independent free WARP accounts in parallel behind HAProxy for rate-limit distribution and automatic failover, plus periodic identity rotation, Prometheus metrics, IP allowlist, and per-IP rate limiting.

Built on [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) (Go MASQUE/WARP client) and `linuxserver/baseimage-alpine` + `s6-overlay`.

## Quickstart

```sh
docker run -d --name warp-masque \
  -p 1080:1080 \
  -v "$PWD/config:/config" \
  ghcr.io/akumaginkou/warp-masque:latest

curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# expect: warp=on
```

First boot runs `usque register` and writes `/config/config.json`. Mount `/config` to a host volume to keep the account across restarts.

## Why MASQUE?

- **DPI / UDP-blocking networks**: corporate, mobile, in-flight, and some ISPs drop WireGuard. The official Cloudflare app gave up WireGuard for MASQUE first; this image follows.
- **`USE_HTTP2=true`** falls all the way back to TLS-over-TCP, which traverses almost anything that lets HTTPS out.
- **No `WARP_PLUS` farming**. Cloudflare killed the referral API on 2024-11-01 (error `1070`). Free WARP is unmetered and still works.

## Configuration

### Basic

| ENV | Description | Default |
|---|---|---|
| `SOCKS5_PORT` | Public SOCKS5 listener port | `1080` |
| `HTTP_PORT` | If set, also expose an HTTP CONNECT proxy on this port | — |
| `USERNAME` / `PASSWORD` | Optional proxy auth (shared by SOCKS5 and HTTP) | — |
| `DNS` | Comma-separated upstream resolvers (`-d` per entry) | usque default |
| `USE_HTTP2` | `true` to force HTTP/2-over-TLS (use when QUIC is blocked) | `false` |
| `DEVICE_NAME` | Name passed to `usque register -n`. In pool mode, worker `i` becomes `${DEVICE_NAME}-${i}` | — |
| `TZ` | Container timezone | `UTC` |

### Pool mode (advanced)

| ENV | Description | Default |
|---|---|---|
| `ACCOUNT_COUNT` | Number of independent free accounts to provision and run in parallel | `1` |
| `ROTATE_INTERVAL` | Re-register one slot per interval (`60s`, `30m`, `24h`, `1h30m`). Minimum 60 s. Disabled when unset. | — |
| `HAPROXY_STATS_PORT` | Expose HAProxy's stats page on this port | — |
| `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` | Basic auth for the stats page | — |
| `HAPROXY_METRICS_PORT` | Expose Prometheus-format metrics at `/metrics` on this port | — |
| `ALLOW_CIDR` | Comma-separated CIDR allowlist for proxy connections (HAProxy ACL). Connections from any other source are dropped at TCP layer. | unrestricted |
| `RATE_LIMIT_PER_IP` | Max new connections per IP per 10 s window (HAProxy stick-table) | unrestricted |

### TUN mode

| ENV | Description | Default |
|---|---|---|
| `MODE` | `tun` to run as a routable WARP gateway via `usque nativetun` instead of a proxy. Disables all proxy/pool services. | `proxy` |

## Pool mode

Set `ACCOUNT_COUNT=N` (N ≥ 2) and the image:

- Registers N independent free WARP accounts on first boot.
- Runs N `usque socks` workers (and N `usque http-proxy` if `HTTP_PORT` is set), each with its own MASQUE tunnel.
- Fronts the public ports with HAProxy in TCP roundrobin + per-backend health checks + `option redispatch`.

```
client ─▶ :SOCKS5_PORT ─▶ HAProxy ─┬─▶ usque #1 ─▶ MASQUE ─▶ Cloudflare
                                   ├─▶ usque #2 ─▶ MASQUE ─▶ Cloudflare
                                   └─▶ usque #N ─▶ MASQUE ─▶ Cloudflare
```

Example:

```yaml
services:
  warp-masque:
    image: ghcr.io/akumaginkou/warp-masque:latest
    restart: always
    environment:
      - ACCOUNT_COUNT=3
      - HTTP_PORT=1081
      - HAPROXY_STATS_PORT=8404
    volumes:
      - ./config:/config
    ports:
      - 127.0.0.1:1080:1080
      - 127.0.0.1:1081:1081
      - 127.0.0.1:8404:8404
```

What you get:

- **Rate-limit distribution** — each new client TCP connection gets the next account in the rotation.
- **Failover** — if a worker stops responding to TCP health checks, HAProxy stops sending it traffic and retries the request on a healthy backend (`option redispatch`).
- **Per-worker restart** — workers run under independent supervisors with exponential backoff (1 s → 30 s cap). One crashing process doesn't take the rest down.

### Internals

- Worker `i` binds `127.0.0.1:1100i` (SOCKS5) and `127.0.0.1:1200i` (HTTP).
- Account #1 stays in `/config/config.json` so single-account deployments upgrade in place; accounts #2..N live in `/config/config-{2..N}.json`.
- `ACCOUNT_COUNT=1` (default) bypasses HAProxy entirely and binds `usque` directly to the public ports.

### Identity rotation

`ROTATE_INTERVAL=24h` periodically re-registers one pool slot at a time (round-robin across slots, persisted in `/config/rotator.state`). After the new account is written, only the worker for that slot is signalled to restart — the per-worker supervisor picks the new config up within ~1 s, HAProxy stops sending it traffic during the brief gap and resumes once its TCP check passes again. Useful when you want to shift fingerprint over time without dropping the pool.

## TUN mode

`MODE=tun` runs `usque nativetun` instead of any SOCKS5/HTTP listener, giving the container a routable TUN interface (no proxy hop). Routing is deliberately not auto-configured — drop an `on-connect.sh` into `/config` to wire up `ip route add` for the targets you want sent through WARP.

```sh
docker run -d --name warp-masque \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/config:/config" \
  -e MODE=tun \
  ghcr.io/akumaginkou/warp-masque:latest
```

Requirements: `/dev/net/tun` available on the host, `NET_ADMIN` cap. Pool mode and TUN mode are mutually exclusive; `MODE=tun` short-circuits proxy services.

## Security

The container can run with most Linux capabilities dropped. For proxy mode, this minimal set is sufficient and verified:

```sh
docker run -d \
  --cap-drop=ALL \
  --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE \
  -p 1080:1080 \
  ghcr.io/akumaginkou/warp-masque:latest
```

For TUN mode, add `--cap-add=NET_ADMIN --device=/dev/net/tun`. The container runs as the non-root `abc` user (UID 911) for all proxy work; only `usque nativetun` needs root for the TUN device.

Limit who can reach the proxy with `ALLOW_CIDR=10.0.0.0/8,192.168.0.0/16` and throttle abusive clients with `RATE_LIMIT_PER_IP=20`. Both apply at the HAProxy layer in pool mode.

## Observability

`HAPROXY_STATS_PORT` publishes HAProxy's built-in stats page (per-backend session counts, bytes in/out, last health check, up/down state, request rate). Pair with `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` for Basic auth before exposing it past localhost.

`HAPROXY_METRICS_PORT` exposes HAProxy's built-in Prometheus exporter at `/metrics` on the chosen port — drop this straight into a Prometheus `scrape_configs` entry for per-backend session and byte counters, no sidecar required.

The container `HEALTHCHECK` runs every 25 s and combines:

1. End-to-end SOCKS5 probe against `cloudflare.com/cdn-cgi/trace`.
2. (Pool mode) TCP probe of each worker's internal port. The container goes `unhealthy` only when **more than ⌊N/2⌋ workers stop listening** — a single flaky worker doesn't trigger a container restart that would kill the surviving majority.

## Caveats

- **Connection-level distribution.** Each new TCP connection picks the next backend. SOCKS5 opens one TCP socket per target host with no multiplexing, so a browser session, a `curl` loop, or a download manager already gets a different account per outbound stream. Two cases keep a single connection pinned to one backend for its lifetime — by design, since rebalancing mid-stream would break the session: a long-lived TCP stream (FTP control, SSH, SOCKS5-tunneled TLS), and HTTP/2 multiplexing inside one HTTP CONNECT tunnel (a browser reusing one CONNECT to one origin will pin all multiplexed requests to that backend).
- **Egress IP ≠ account identity**. Cloudflare pools egress IPs internally; two of your accounts may surface from the same WARP edge address.
- **Paid WARP+ license keys** aren't supported yet — tracking [usque#87](https://github.com/Diniboy1123/usque/issues/87).
- **TUN mode does not configure routes**. usque deliberately leaves routing to the operator; supply an `on-connect.sh` for `ip route add` if you want the container to route specific traffic.

## Acknowledgements

- [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) — the underlying MASQUE/WARP client.
- [`linuxserver/baseimage-alpine`](https://github.com/linuxserver/docker-baseimage-alpine) — base image + s6-overlay scaffolding.
- [`akumaginkou/warproxy`](https://github.com/akumaginkou/warproxy) — the wireproxy-based predecessor.

## License

MIT — see [LICENSE](LICENSE).
