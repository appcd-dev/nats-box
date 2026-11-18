# syntax=docker/dockerfile:1
# Hardened nats-box 0.20.2.
#
# XRAY-1162975: upstream go-installs nats-top v0.6.5, which links nats-server
# v2.15.1. This build compiles nats-top v0.6.5 against nats-server v2.15.3.
# natscli v0.5.1 already links v2.15.2, which includes the fix.
#
# CVE-2026-4738: the running tools need Alpine (shell, curl, jq, figlet), so
# zlib stays, but it is 1.4-r0. The published image is one layer copied from
# that rootfs onto scratch. The Alpine base layers, which contain zlib 1.3.2,
# are not in the image Xray scans.

FROM golang:1.27.3-alpine3.24 AS nats-top

RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch v0.6.5 https://github.com/nats-io/nats-top.git .
ENV CGO_ENABLED=0
RUN go get github.com/nats-io/nats-server/v2@v2.15.3 \
    && go mod tidy \
    && go build -trimpath -buildvcs=false \
        -ldflags "-s -w -X main.version=0.6.5" \
        -o /out/nats-top . \
    && go version -m /out/nats-top | grep 'nats-server/v2' | grep -q 'v2.15.3' \
    && if go version -m /out/nats-top | grep 'nats-server/v2' | grep -q 'v2.15.1'; then \
         echo "nats-top still links nats-server v2.15.1" >&2; exit 1; \
       fi

FROM golang:1.27.3-alpine3.24 AS tools

ARG TARGETARCH
ENV CGO_ENABLED=0
ENV GOPATH=/go/${TARGETARCH}

RUN mkdir -p "${GOPATH}" \
    && go install -ldflags "-X main.version=2.15.0" github.com/nats-io/nsc/v2@v2.15.0 \
    && go install -ldflags "-X main.version=0.5.1" github.com/nats-io/natscli/nats@v0.5.1 \
    && go install -ldflags "-X main.version=0.4.16" github.com/nats-io/nkeys/nk@v0.4.16 \
    && if go version -m "${GOPATH}/bin/"* | grep 'nats-server/v2' | grep -q 'v2.15.1'; then \
         echo "a nats-box tool still links nats-server v2.15.1" >&2; \
         go version -m "${GOPATH}/bin/"* | grep 'nats-server/v2' || true; \
         exit 1; \
       fi

FROM alpine:3.24.3 AS rootfs

ARG TARGETARCH

RUN set -eux; \
    apk -U upgrade; \
    apk add --no-cache ca-certificates curl figlet jq; \
    apk add --no-cache --upgrade 'zlib=1.4-r0'; \
    zlib_ver="$(apk list -I zlib)"; \
    echo "${zlib_ver}"; \
    echo "${zlib_ver}" | grep -q '^zlib-1.4-r0 '; \
    echo "${zlib_ver}" | grep -q '1.3' && exit 1 || true; \
    rm -rf /var/cache/apk; \
    mkdir /var/cache/apk; \
    addgroup -g 1000 nats; \
    adduser -D -u 1000 -G nats nats; \
    mkdir -p /nsc; \
    chown nats:root /nsc /home/nats; \
    chmod 0775 /nsc /home/nats

COPY --from=tools /go/${TARGETARCH}/bin/ /usr/local/bin/
COPY --from=nats-top /out/nats-top /usr/local/bin/nats-top
COPY entrypoint.sh /entrypoint.sh
COPY profile.sh /etc/profile.d/profile.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/nats-top

FROM scratch

COPY --from=rootfs / /

ENV NKEYS_PATH=/nsc/nkeys \
    XDG_DATA_HOME=/nsc \
    XDG_CONFIG_HOME=/nsc/.config \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

ENTRYPOINT ["/entrypoint.sh"]

LABEL org.opencontainers.image.title="nats-box" \
      org.opencontainers.image.source="https://github.com/nats-io/nats-box" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="0.20.2"
