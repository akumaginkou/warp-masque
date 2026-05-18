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
| `DEVICE_NAME` | Friendly name passed to `usque register -n` on first boot | (unset) |
| `TZ` | Container timezone | `UTC` |

## Verifying

```sh
curl -sx socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# expect: warp=on
```

## Notes

- `WARP_PLUS` quota farming is **not implemented** and will not be — the API behind it is gone.
- Multi-account rotation is also out of scope here; if you need it, run multiple containers behind a load balancer.
- License key (paid WARP+) injection is **not yet supported** upstream in usque ([issue #87](https://github.com/Diniboy1123/usque/issues/87)).

## License

MIT.
