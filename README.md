# warp-masque

Cloudflare WARP as a SOCKS5/HTTP proxy, spoken over **MASQUE/HTTP/3** — the same protocol Cloudflare's own 1.1.1.1 mobile app uses. Drops in where WireGuard-based wrappers (e.g. wireproxy) get blocked by UDP/DPI filters, and falls back to HTTP/2 when QUIC is unreachable.

Built on:
- [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) — Go implementation of WARP over MASQUE.
- `linuxserver/baseimage-alpine` + `s6-overlay` for supervision.

## Why not warproxy?

- The classic WireGuard/UDP transport (wireproxy + wgcf) is blocked on a growing number of corporate, mobile, and airline networks.
- The WARP+ referral program that wgcf-based images farmed for extra quota was **terminated by Cloudflare on 2024-11-01** (API error `1070`). Free WARP itself still works.
- MASQUE/HTTP3 is what the official Cloudflare app falls through to first; HTTP/2 over TCP is a final fallback.

## Usage

```sh
docker run -d --name warp-masque \
  -p 1080:1080 \
  -v $PWD/config:/config \
  ghcr.io/akumaginkou/warp-masque:latest
```

or `docker-compose`:

```yaml
services:
  warp-masque:
    image: ghcr.io/akumaginkou/warp-masque:latest
    restart: always
    environment:
      - HTTP_PORT=1081
    volumes:
      - ./config:/config
    ports:
      - 127.0.0.1:1080:1080
      - 127.0.0.1:1081:1081
```

On first boot the container runs `usque register` and writes `/config/config.json`. Mount `/config` to a host volume to persist the account across restarts.

## Environment variables

| ENV | Description | Default |
|---|---|---|
| `SOCKS5_PORT` | Port for the SOCKS5 listener | `1080` |
| `HTTP_PORT` | If set, also start an HTTP CONNECT proxy on this port | (unset) |
| `USERNAME` | Optional SOCKS5/HTTP proxy username | (unset) |
| `PASSWORD` | Optional SOCKS5/HTTP proxy password | (unset) |
| `DNS` | Comma-separated upstream DNS list (forwarded as `-d`) | (unset, usque default) |
| `USE_HTTP2` | `true` to force HTTP/2 over TCP+TLS (use when QUIC is blocked) | `false` |
| `DEVICE_NAME` | Friendly name passed to `usque register -n` on first boot. With pooling, account #i gets `${DEVICE_NAME}-${i}` | (unset) |
| `ACCOUNT_COUNT` | Provision N free accounts and pool them behind an internal HAProxy (TCP roundrobin + per-backend failover). `1` = legacy single-account mode. | `1` |
| `TZ` | Container timezone | `UTC` |

## Multi-account pooling

Set `ACCOUNT_COUNT=N` (N ≥ 2) to provision N independent free WARP accounts on first boot and run them in parallel behind an internal HAProxy. Each new client connection on the public SOCKS5 port is round-robined to a different account, distributing per-account rate limits and identification. Per-backend TCP health checks plus HAProxy's `option redispatch` give automatic failover if any individual `usque` worker becomes unreachable — the connection retries on the next live backend.

```yaml
services:
  warp-masque:
    image: ghcr.io/akumaginkou/warp-masque:latest
    restart: always
    environment:
      - ACCOUNT_COUNT=3
      - HTTP_PORT=1081
    volumes:
      - ./config:/config   # persists all N account credentials
    ports:
      - 127.0.0.1:1080:1080
      - 127.0.0.1:1081:1081
```

Internally:
- Worker `i` binds `127.0.0.1:1100i` (SOCKS5) and `127.0.0.1:1200i` (HTTP, if `HTTP_PORT` set).
- HAProxy fronts `:${SOCKS5_PORT}` and `:${HTTP_PORT}` with `balance roundrobin`.
- Account #1 stays in `/config/config.json` (so upgrades from single-account deployments keep working); accounts #2..N live in `/config/config-{2..N}.json`.

`N=1` (the default) bypasses HAProxy entirely and binds `usque` directly to the public ports — no extra hop, no behavior change from the single-account image.

## Verifying

```sh
curl -sx socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# expect: warp=on
```

## Notes

- `WARP_PLUS` quota farming is **not implemented** and will not be — the API behind it is gone.
- License key (paid WARP+) injection is **not yet supported** upstream in usque ([issue #87](https://github.com/Diniboy1123/usque/issues/87)).
- Pool members are connection-level round-robin (HAProxy `mode tcp`), not request-level. A long-lived SOCKS5 connection stays on the same backend for its lifetime.

## License

MIT.
