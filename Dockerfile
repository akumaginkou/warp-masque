ARG ALPINE_VER=3.23
ARG GOLANG_VER=1.26

#--------------#

FROM ghcr.io/linuxserver/baseimage-alpine:${ALPINE_VER} AS base

#--------------#

FROM golang:${GOLANG_VER}-alpine${ALPINE_VER} AS usque-builder
RUN go install -ldflags="-s -w" github.com/Diniboy1123/usque@latest

#--------------#

FROM base AS collector

COPY --from=usque-builder /go/bin/usque /bar/usr/local/bin/usque

COPY root/ /bar/

RUN chmod a+x \
        /bar/usr/local/bin/* \
        /bar/etc/s6-overlay/s6-rc.d/*/run \
        /bar/etc/s6-overlay/s6-rc.d/*/finish \
        /bar/etc/s6-overlay/s6-rc.d/*/data/* 2>/dev/null || true

#--------------#

FROM base AS publisher

LABEL maintainer="akumaginkou"
LABEL org.opencontainers.image.source=https://github.com/akumaginkou/warp-masque
LABEL org.opencontainers.image.description="Cloudflare WARP as a SOCKS5/HTTP proxy over MASQUE (HTTP/3)"

COPY --from=collector /bar/ /

RUN apk add --no-cache curl haproxy

ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    TZ=UTC \
    SOCKS5_PORT=1080

VOLUME /config
WORKDIR /config

HEALTHCHECK --interval=25s --timeout=5s --retries=3 \
    CMD /usr/local/bin/healthcheck

ENTRYPOINT ["/init"]
