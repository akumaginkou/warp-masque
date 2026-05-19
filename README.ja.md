# warp-masque

[English](README.md) | 日本語

Cloudflare WARP を SOCKS5/HTTP プロキシ (またはルータブル TUN ゲートウェイ) として、**MASQUE/HTTP/3** で喋らせるイメージ。Cloudflare 公式 1.1.1.1 モバイルアプリと同じプロトコルです。WireGuard ラッパーが UDP / DPI で潰される環境でも通り、QUIC まで弾かれる場合は `USE_HTTP2=true` で HTTP/2-over-TLS にフォールバック。

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

初回起動で `usque register` が走り `/config/config.json` を作成。`/config` をホスト volume にマウントすればアカウントが永続化されます。`linux/amd64` と `linux/arm64` の両方を公開。

## なぜ MASQUE?

- **DPI / UDP ブロック環境**: 企業 NW、モバイル、機内 Wi-Fi、一部 ISP は WireGuard を落とすことがある。Cloudflare 公式アプリも同じ理由で MASQUE に移った
- **`USE_HTTP2=true`** で TLS-over-TCP までフォールバック。HTTPS が通る環境ならほぼ貫通

## Pool モード

`ACCOUNT_COUNT=N` (N ≥ 2) で N 個の独立したフリー WARP アカウントを並列起動し、HAProxy 越しでレート制限分散とフェイルオーバーを実現します。

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

- **Roundrobin** — 新しいクライアント TCP 接続ごとに次の worker アカウントへ振り分け
- **フェイルオーバー** — backend ごとの TCP ヘルスチェック + HAProxy `option redispatch`。死んだ worker は外され、in-flight は生存 backend に retry
- **Per-worker supervision** — 各 worker は独立 supervisor、exp backoff (1 s → 30 s 上限)。1 つの暴走で全体が落ちることはない
- **識別ローテーション** (`ROTATE_INTERVAL`) — スロットを順番に定期再登録。`/config/rotator.state` に進行状況を永続化、短時間の worker restart は HAProxy redispatch がマスク

内部仕様: worker `i` は `127.0.0.1:1100i` (SOCKS5)、`127.0.0.1:1200i` (HTTP) を listen。アカウント #1 は `/config/config.json` のまま (単一アカウント運用からの upgrade を壊さない)、#2..N は `/config/config-{2..N}.json`。`ACCOUNT_COUNT=1` (既定) では HAProxy を経由せず `usque` を公開ポートに直 bind。

## TUN ゲートウェイモード

`MODE=tun` で SOCKS5/HTTP リスナーの代わりに `usque nativetun` が起動し、コンテナがルータブル TUN インターフェイスを持ちます。usque は意図的にルートを自動設定しないので、WARP 経由にしたい宛先について `ip route add` を書く実行可能な `/config/on-connect.sh` を置いてください。

```sh
docker run -d --name warp-masque \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/config:/config" \
  -e MODE=tun \
  ghcr.io/akumaginkou/warp-masque:latest
```

要件: ホスト側に `/dev/net/tun`、`NET_ADMIN` cap。Pool モードと TUN モードは排他で、`MODE=tun` 設定時に proxy / HAProxy 系サービスが全停止します。

## 設定

### 基本

| ENV | 説明 | 既定値 |
|---|---|---|
| `SOCKS5_PORT` | 公開 SOCKS5 リスナーのポート | `1080` |
| `HTTP_PORT` | 設定時、HTTP CONNECT プロキシも公開 | — |
| `USERNAME` / `PASSWORD` | プロキシ認証 (SOCKS5/HTTP 共通) | — |
| `DNS` | カンマ区切りの上位 DNS (各値が `-d` 引数になる) | usque 既定 |
| `USE_HTTP2` | `true` で HTTP/2-over-TLS 強制 (QUIC が弾かれる環境用) | `false` |
| `DEVICE_NAME` | `usque register -n` に渡す名前。Pool モードでは worker `i` が `${DEVICE_NAME}-${i}` になる | — |
| `TZ` | コンテナのタイムゾーン | `UTC` |

### Pool

| ENV | 説明 | 既定値 |
|---|---|---|
| `ACCOUNT_COUNT` | 並列起動するフリーアカウント数 | `1` |
| `ROTATE_INTERVAL` | スロット 1 個ずつ周期的に再登録 (`60s`, `30m`, `24h`, `1h30m`)。最小 60 秒 | — |
| `HAPROXY_STATS_PORT` | HAProxy stats ページの公開ポート | — |
| `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` | stats ページの Basic 認証 | — |
| `HAPROXY_METRICS_PORT` | `/metrics` で Prometheus 形式メトリクスを公開するポート | — |
| `ALLOW_CIDR` | プロキシ接続を許可する CIDR (カンマ区切り)。それ以外は TCP 層で reject | 制限なし |
| `RATE_LIMIT_PER_IP` | クライアント IP 単位の 10 秒窓内最大新規接続数 | 制限なし |

### TUN

| ENV | 説明 | 既定値 |
|---|---|---|
| `MODE` | `tun` で `usque nativetun` ベースのルータブル WARP ゲートウェイとして起動 | `proxy` |

## 観測 / Observability

- **Stats ページ** (`HAPROXY_STATS_PORT`) — HAProxy 組み込みダッシュボード。各 backend のセッション数、in/out バイト、直近のヘルスチェック結果、up/down 状態を一望。localhost より外に出すなら `HAPROXY_STATS_USER` / `HAPROXY_STATS_PASS` で Basic 認証を必ず併設
- **Prometheus メトリクス** (`HAPROXY_METRICS_PORT`) — HAProxy 標準の `/metrics` exporter。サイドカー不要で `scrape_configs` に直接登録できる
- **HEALTHCHECK** — 25 秒間隔で「公開 SOCKS5 経由の `cloudflare.com/cdn-cgi/trace` 到達確認」+ (Pool モード時) 「各 worker 内部ポートの TCP 疎通確認」を実施。**死亡 worker が ⌊N/2⌋ を超えたとき**のみ `unhealthy` 判定 — 少数の不調 worker で container 再起動を起こして残りを巻き添えにしない

## セキュリティ

プロキシ系処理は全て非 root の `abc` (UID 911) で実行。`--cap-drop=ALL` で動作確認済 (最小セット):

```sh
docker run -d \
  --cap-drop=ALL \
  --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE \
  -p 1080:1080 \
  ghcr.io/akumaginkou/warp-masque:latest
```

TUN モード時は加えて `--cap-add=NET_ADMIN --device=/dev/net/tun`。

ネットワーク層では `ALLOW_CIDR=10.0.0.0/8,192.168.0.0/16` でアクセス元を絞り、`RATE_LIMIT_PER_IP=20` で乱用クライアントを抑制 (両方 Pool モードの HAProxy 機能)。

## 制約 / Caveats

- **接続単位の振り分け**。SOCKS5 は target ごとに 1 本 TCP を開く設計で多重化しないので、ブラウザのページ遷移も `curl` もダウンロードも、実質的に outbound stream 単位で別アカウントになる。長寿命の単一ストリーム (FTP コントロール、SSH、SOCKS5 上の TLS) と、1 つの CONNECT トンネル内での HTTP/2 多重化のみ、最初の connect が落ちた backend に張り付く — 途中で切り替えると壊れるので意図通り
- **egress IP = アカウント数ではない**。Cloudflare 側で egress IP がプール化されているため、別アカウントでも同じ WARP edge IP に出ることがある
- **WARP+ farming は非搭載**。Cloudflare が referral API を 2024-11-01 に終了 (error `1070`)。フリー WARP は無制限・無期限で使える
- **有料 WARP+ ライセンスキー注入は未対応**。upstream usque の [issue #87](https://github.com/Diniboy1123/usque/issues/87) を追跡中
- **TUN モードはルート自動設定しない**。usque 仕様。`on-connect.sh` で `ip route add` を自前管理

## 謝辞

- [`Diniboy1123/usque`](https://github.com/Diniboy1123/usque) — 中身の MASQUE/WARP クライアント
- [`linuxserver/baseimage-alpine`](https://github.com/linuxserver/docker-baseimage-alpine) — ベース image + s6-overlay 周り
- [`akumaginkou/warproxy`](https://github.com/akumaginkou/warproxy) — wireproxy ベースの前身

## ライセンス

MIT — 詳しくは [LICENSE](LICENSE)。
