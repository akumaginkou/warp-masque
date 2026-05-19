# warp-masque

English | [日本語](README.ja.md)

Cloudflare WARP as a SOCKS5/HTTP proxy — or a routable TUN gateway — spoken over **MASQUE/HTTP/3** like the official 1.1.1.1 mobile app. Drops in where WireGuard wrappers get blocked by UDP/DPI filters, with an HTTP/2 fallback when QUIC is unreachable.

Built on [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) (Go MASQUE/WARP client) + `linuxserver/baseimage-alpine` + `s6-overlay`.

## Quickstart

```sh
docker run -d --name warp-masque \
  -p 1080:1080 \
  -v "$PWD/config:/config" \
  ghcr.io/akumaginkou/warp-masque:latest

curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# expect: warp=on
```

First boot runs `usque register` and writes `/config/config.json`. Mount `/config` to a host volume to persist the account across restarts. Images are published for `linux/amd64` and `linux/arm64`.

## Why MASQUE?

- **DPI / UDP-blocking networks**: corporate, mobile, in-flight, some ISPs drop WireGuard. The Cloudflare app moved to MASQUE for the same reason; this image follows.
- **`USE_HTTP2=true`** falls back to TLS-over-TCP, which traverses almost anything that lets HTTPS out.

## Pool mode

`ACCOUNT_COUNT=N` (N ≥ 2) provisions N independent free WARP accounts and pools them behind HAProxy for rate-limit distribution and automatic failover.

```
client ─▶ :SOCKS5_PORT ─▶ HAProxy ─┬─▶ usque #1 ─▶ MASQUE ─▶ Cloudflare
                                   ├─▶ usque #2 ─▶ MASQUE ─▶ Cloudflare
                                   └─▶ usque #N ─▶ MASQUE ─▶ Cloudflare
```

```yaml
services:
  warp-masque:
    image: ghcr.io/akumaginkou/warp-masque:latest
    restart: always
    environment:
      - ACCOUNT_COUNT=3
      - ROTATE_INTERVAL=24h
      - HTTP_PORT=1081
      - HAPROXY_STATS_PORT=8404
      - HAPROXY_METRICS_PORT=9101
    volumes:
      - ./config:/config
    ports:
      - 127.0.0.1:1080:1080
      - 127.0.0.1:1081:1081
      - 127.0.0.1:8404:8404
      - 127.0.0.1:9101:9101
```

- **Roundrobin** across worker accounts on every new client connection.
- **Failover** via per-backend TCP health checks + HAProxy `option redispatch` — a dead worker is bypassed, in-flight requests retry on a live one.
- **Per-worker supervision** with exponential backoff (1 s → 30 s cap). One crashing process doesn't drag the rest down.
- **Identity rotation** (`ROTATE_INTERVAL`) re-registers one pool slot at a time on a timer. Round-robin across slots, state persisted in `/config/rotator.state`. The brief restart window is masked by HAProxy redispatch.

Internals: worker `i` binds `127.0.0.1:1100i` (SOCKS5) and `127.0.0.1:1200i` (HTTP). Account #1 stays in `/config/config.json` so existing single-account deployments upgrade in place; accounts #2..N live in `/config/config-{2..N}.json`. `ACCOUNT_COUNT=1` (default) bypasses HAProxy entirely.

## TUN gateway mode

`MODE=tun` runs `usque nativetun` instead of any proxy listener, giving the container a routable TUN interface. usque deliberately does not configure routes — drop an executable `/config/on-connect.sh` to wire up `ip route add` for the destinations you want sent through WARP.

```sh
docker run -d --name warp-masque \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/config:/config" \
  -e MODE=tun \
  ghcr.io/akumaginkou/warp-masque:latest
```

Requirements: `/dev/net/tun` present on the host, `NET_ADMIN` capability. Mutually exclusive with pool mode — `MODE=tun` short-circuits the proxy/HAProxy services.

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

### Pool

| ENV | Description | Default |
|---|---|---|
| `ACCOUNT_COUNT` | Number of free accounts to provision and run in parallel | `1` |
| `ROTATE_INTERVAL` | Re-register one slot per interval (`60s`, `30m`, `24h`, `1h30m`). Min 60 s. | — |
| `HAPROXY_STATS_PORT` | Expose HAProxy's stats page on this port | — |
| `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` | Basic auth for the stats page | — |
| `HAPROXY_METRICS_PORT` | Expose Prometheus-format metrics at `/metrics` on this port | — |
| `ALLOW_CIDR` | Comma-separated CIDR allowlist for proxy connections (TCP-layer reject) | unrestricted |
| `RATE_LIMIT_PER_IP` | Max new connections per IP per 10 s window | unrestricted |

### TUN

| ENV | Description | Default |
|---|---|---|
| `MODE` | `tun` to run as a routable WARP gateway via `usque nativetun` | `proxy` |

## Observability

- **Stats page** (`HAPROXY_STATS_PORT`) — HAProxy's built-in dashboard: per-backend session counts, bytes in/out, last health check, up/down state. Add `HAPROXY_STATS_USER`/`HAPROXY_STATS_PASS` for Basic auth before exposing past localhost.
- **Prometheus metrics** (`HAPROXY_METRICS_PORT`) — HAProxy's `/metrics` exporter, no sidecar needed. Point your `scrape_configs` at it.
- **HEALTHCHECK** runs every 25 s and combines an end-to-end SOCKS5 probe against `cloudflare.com/cdn-cgi/trace` with (in pool mode) a TCP probe of each worker's internal port. The container only flips to `unhealthy` once **more than ⌊N/2⌋ workers stop listening** — a single flaky worker doesn't trigger a restart that would kill the surviving majority.

## Security

The container runs as non-root `abc` (UID 911) for all proxy work and is verified against `--cap-drop=ALL` with this minimal set:

```sh
docker run -d \
  --cap-drop=ALL \
  --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE \
  -p 1080:1080 \
  ghcr.io/akumaginkou/warp-masque:latest
```

TUN mode additionally requires `--cap-add=NET_ADMIN --device=/dev/net/tun`.

At the network layer, restrict who can reach the proxy with `ALLOW_CIDR=10.0.0.0/8,192.168.0.0/16` and throttle abusive clients with `RATE_LIMIT_PER_IP=20` (both pool-mode HAProxy features).

## Caveats

- **Connection-level distribution.** SOCKS5 opens one TCP socket per target host, so every browser navigation / `curl` / download already rotates accounts. A long-lived single stream (FTP control, SSH, SOCKS5-tunneled TLS) and HTTP/2 multiplexed inside one CONNECT tunnel both stay on whichever backend handled the initial connect — by design, since mid-stream rebalancing would break the session.
- **Egress IP ≠ account identity.** Cloudflare pools WARP egress IPs internally; two accounts may surface from the same edge address.
- **No WARP+ farming.** Cloudflare retired the referral API on 2024-11-01 (error `1070`). Free WARP itself is unmetered and still works.
- **Paid WARP+ license keys** aren't supported yet — tracking [usque#87](https://github.com/Diniboy1123/usque/issues/87).
- **TUN mode does not auto-configure routes.** usque leaves routing to the operator by design; supply an `on-connect.sh` if you want the container to route specific traffic.

## Acknowledgements

- [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) — the underlying MASQUE/WARP client.
- [`linuxserver/baseimage-alpine`](https://github.com/linuxserver/docker-baseimage-alpine) — base image + s6-overlay scaffolding.
- [`akumaginkou/warproxy`](https://github.com/akumaginkou/warproxy) — the wireproxy-based predecessor.

## License

MIT — see [LICENSE](LICENSE).
