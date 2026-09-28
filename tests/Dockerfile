# syntax=docker/dockerfile:1
# ──────────────────────────────────────────────────────────────────
# Netshift Evolution — OpenWrt Smoke Test Container
#
# Purpose:
#   Run netshift in an OpenWrt rootfs container to verify functionality
#   BEFORE deploying to a physical router.
#
# What this tests:
#   ✓ Dependency availability (sing-box, curl, jq, base64, dig)
#   ✓ UCI config parsing and validation
#   ✓ Shell script syntax (ash) — all sourced libraries
#   ✓ sing-box config generation (dry run)
#   ✓ Helper functions (HWID, URL parsing, IP validation)
#   ✓ Subscription URL handling
#   ✓ nftables rules syntax (table creation, rule generation)
#   ✓ dnsmasq config backup/restore
#   ✓ Service lifecycle (start/stop/reload)
#   ✓ Diagnostics (check_sing_box, check_nft_rules, global_check)
#
# Limitations (kernel-level features):
#   ✗ TProxy packet interception (needs real kernel + kmod-nft-tproxy)
#   ✗ Full sing-box runtime (needs real network interfaces)
#   ✗ Clash API WebSocket (needs running sing-box process)
#
# Usage:
#   docker compose -f tests/docker-compose.yml up --build
#   docker compose -f tests/docker-compose.yml run --rm netshift-test
# ──────────────────────────────────────────────────────────────────

# ── Stage 1: Загрузка официального чистого rootfs ─────────────────
FROM --platform=linux/amd64 alpine:latest AS builder
WORKDIR /rootfs
# Скачиваем и распаковываем оригинальный OpenWrt 24.10.6
RUN apk add --no-cache curl tar gzip && \
    curl -sSL https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/openwrt-24.10.6-x86-64-rootfs.tar.gz | tar -xz

# sing-box-extended рядом со стоковым ядром, а не вместо него: остальные тесты
# гоняют стоковый sing-box, а тесты фич extended (VLESS Encryption) вызывают
# /usr/local/bin/sing-box-extended для настоящего `sing-box check`.
# Версия закреплена, архив сверяется по sha256.
ARG SB_EXTENDED_VERSION=1.13.14-extended-2.5.3
ARG SB_EXTENDED_SHA256=c4b6a7367fc25e7a37289ea917fbf836d385b552a097ea5f643480d7fbe2768f
RUN curl -sSL -o /tmp/sbx.tar.gz \
        "https://github.com/shtorm-7/sing-box-extended/releases/download/v${SB_EXTENDED_VERSION}/sing-box-${SB_EXTENDED_VERSION}-linux-amd64-musl.tar.gz" && \
    echo "${SB_EXTENDED_SHA256}  /tmp/sbx.tar.gz" | sha256sum -c - && \
    mkdir -p /rootfs/usr/local/bin && \
    tar -xzf /tmp/sbx.tar.gz -C /tmp && \
    install -m 0755 "/tmp/sing-box-${SB_EXTENDED_VERSION}-linux-amd64-musl/sing-box" /rootfs/usr/local/bin/sing-box-extended && \
    rm -rf /tmp/sbx.tar.gz "/tmp/sing-box-${SB_EXTENDED_VERSION}-linux-amd64-musl"

# ── Stage 2: Сборка финального контейнера ─────────────────────────
FROM scratch
# Переносим настоящую систему OpenWrt
COPY --from=builder /rootfs /

LABEL org.opencontainers.image.title="Netshift Evolution Test"
LABEL org.opencontainers.image.description="Official OpenWrt 24.10.6 rootfs for Netshift testing"

# Для корректной работы opkg внутри пустого Docker нужна эта директория
RUN mkdir -p /var/lock

# ── Install runtime dependencies ─────────────────────────────────
RUN opkg update && \
    opkg install \
        sing-box \
        curl \
        jq \
        coreutils-base64 \
        bind-dig \
        nftables \
    && rm -rf /var/opkg-lists/*

# ── Create netshift directory structure ───────────────────────────
RUN mkdir -p /usr/lib/netshift \
    /tmp/sing-box/rulesets \
    /tmp/sing-box/subscriptions \
    /var/run

# ── Copy netshift source files ────────────────────────────────────
# All shell scripts, config, and init files are mounted at runtime
# via docker-compose volumes. This image contains only the base OS
# and dependencies. See docker-compose.yml for bind mounts.

# ── Prepare a minimal /etc/config/netshift for testing ────────────
# (real config will be mounted by docker-compose or entrypoint)
COPY netshift/files/etc/config/netshift /etc/config/netshift.test

# ── Pre-create /lib/functions paths (OpenWrt UCI stubs) ───────────
# The rootfs image may not include the full UCI subsystem.
# The entrypoint script handles this gracefully.

# ── Set up entrypoint ────────────────────────────────────────────
COPY tests/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /netshift
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["all"]
