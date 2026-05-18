# warp-masque

[English](README.md) | 日本語

Cloudflare WARP を **MASQUE/HTTP/3** で喋らせる SOCKS5/HTTP プロキシ。Cloudflare 公式 1.1.1.1 モバイルアプリと同じプロトコルです。WireGuard ベースのラッパーが UDP / DPI で潰される環境でも通り、QUIC まで弾かれている場合は `USE_HTTP2=true` で HTTPS-over-TCP までフォールバックします。Pool モードを使うと N 個の独立したフリー WARP アカウントを並列起動して HAProxy 越しに分散・フェイルオーバーします。

ベース: [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) (Go 製 MASQUE/WARP クライアント) + `linuxserver/baseimage-alpine` + `s6-overlay`。

## クイックスタート

```sh
docker run -d --name warp-masque \
  -p 1080:1080 \
  -v "$PWD/config:/config" \
  ghcr.io/akumaginkou/warp-masque:latest

curl -x socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
# 期待: warp=on
```

初回起動で `usque register` が走り `/config/config.json` を作成します。`/config` をホスト volume にマウントすればアカウントが永続化され、再起動で同じ device が使われます。

## なぜ MASQUE?

- **DPI / UDP ブロック環境**: 企業 NW、モバイル、機内 Wi-Fi、一部 ISP は WireGuard を落とすことがあります。Cloudflare 公式アプリも MASQUE を優先しており、本イメージもそれに倣っています。
- **`USE_HTTP2=true`** で TLS-over-TCP までフォールバックする。HTTPS が通る環境なら大体貫通します。
- **`WARP_PLUS` farming は非搭載**。Cloudflare が referral API を 2024-11-01 に終了 (error `1070`)。フリー WARP は無制限・無期限で使えます。

## 設定

### 基本

| ENV | 説明 | 既定値 |
|---|---|---|
| `SOCKS5_PORT` | 公開 SOCKS5 リスナーのポート | `1080` |
| `HTTP_PORT` | 設定時、HTTP CONNECT プロキシも公開 | — |
| `USERNAME` / `PASSWORD` | プロキシ認証 (SOCKS5/HTTP 共通) | — |
| `DNS` | カンマ区切りの上位 DNS (各値が `-d` 引数になる) | usque デフォルト |
| `USE_HTTP2` | `true` で HTTP/2-over-TLS 強制 (QUIC が弾かれる環境用) | `false` |
| `DEVICE_NAME` | `usque register -n` に渡す名前。Pool モードでは worker `i` が `${DEVICE_NAME}-${i}` になる | — |
| `TZ` | コンテナのタイムゾーン | `UTC` |

### Pool モード (高度)

| ENV | 説明 | 既定値 |
|---|---|---|
| `ACCOUNT_COUNT` | 並列起動するフリーアカウント数 | `1` |
| `HAPROXY_STATS_PORT` | HAProxy stats ページの公開ポート (Pool モード限定) | — |
| `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` | stats ページの Basic 認証 | — |

## Pool モード

`ACCOUNT_COUNT=N` (N ≥ 2) を渡すと:

- 初回起動で N 個の独立したフリー WARP アカウントを登録
- N 個の `usque socks` worker (および `HTTP_PORT` 設定時は N 個の `usque http-proxy`) をそれぞれ独立した MASQUE tunnel 上で起動
- 公開ポートを HAProxy で受け、TCP roundrobin + backend ヘルスチェック + `option redispatch` でフェイルオーバー

```
client ─▶ :SOCKS5_PORT ─▶ HAProxy ─┬─▶ usque #1 ─▶ MASQUE ─▶ Cloudflare
                                   ├─▶ usque #2 ─▶ MASQUE ─▶ Cloudflare
                                   └─▶ usque #N ─▶ MASQUE ─▶ Cloudflare
```

例:

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

これで得られるもの:

- **レート制限の分散** — 新しいクライアント TCP 接続ごとに次のアカウントへ振り分け
- **フェイルオーバー** — TCP ヘルスチェックで NG になった worker は HAProxy が外し、`option redispatch` で別の生存 backend にリクエストを retry
- **Worker 単位の自動復旧** — 各 worker は独立したスーパーバイザー下にあり、exp backoff (1 s → 30 s 上限) で再起動。1 つの暴走で pool 全体が落ちることはない

### 内部構成

- Worker `i` は `127.0.0.1:1100i` (SOCKS5)、`127.0.0.1:1200i` (HTTP) を listen
- アカウント #1 は `/config/config.json` のまま (単一アカウント運用からの upgrade を破壊しない)、#2..N は `/config/config-{2..N}.json`
- `ACCOUNT_COUNT=1` (既定) は HAProxy を経由せず `usque` を公開ポートに直 bind

## 観測 / Observability

`HAPROXY_STATS_PORT` を設定すると HAProxy の組み込み stats ページが公開されます (各 backend のセッション数、in/out バイト、直近のヘルスチェック結果、up/down 状態、req/s)。localhost より外に出すなら `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` で Basic 認証を必ず併設してください。

コンテナの `HEALTHCHECK` は 25 秒間隔で 2 段:

1. 公開 SOCKS5 経由で `cloudflare.com/cdn-cgi/trace` まで実際に到達するかを確認
2. (Pool モード時) 各 worker の内部ポートに対する TCP 疎通チェック。**死亡 worker が ⌊N/2⌋ を超えたとき**のみ `unhealthy` 判定。少数の不調 worker で container 自体を再起動して残りまで巻き添えにすることを避ける設計

## 制約 / Caveats

- **接続単位の roundrobin** であってリクエスト単位ではない。長寿命の SOCKS5 接続は同じ backend を使い続ける
- **egress IP = アカウント数とは限らない**。Cloudflare 側で egress IP がプール化されているため、別アカウントでも同じ WARP edge IP に出ることがある
- **有料 WARP+ ライセンスキー注入は未対応**。upstream usque の [issue #87](https://github.com/Diniboy1123/usque/issues/87) を追跡中
- **identity 自動ローテーションはまだ無い**。アカウントは `config*.json` を消すまで持続

## 謝辞

- [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) — 中身の MASQUE/WARP クライアント
- [`linuxserver/baseimage-alpine`](https://github.com/linuxserver/docker-baseimage-alpine) — ベース image + s6-overlay 周り
- [`akumaginkou/warproxy`](https://github.com/akumaginkou/warproxy) — wireproxy ベースの前身

## ライセンス

MIT — 詳しくは [LICENSE](LICENSE)。
