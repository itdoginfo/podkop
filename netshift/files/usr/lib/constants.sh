# shellcheck shell=ash
# shellcheck disable=SC2034

NETSHIFT_VERSION="__COMPILED_VERSION_VARIABLE__"
## Common
NETSHIFT_CONFIG="/etc/config/netshift"
NETSHIFT_STATE_DIR="/etc/netshift"
# The live sing-box cache DB (settings.cache_path, /tmp/sing-box/cache.db by
# default) is on tmpfs, and it is where sing-box keeps the server picked in a
# selector. The DB is copied to flash when the selection changes and put back
# before sing-box starts after a reboot. The selection file holds the choice the
# copy was taken with, so FakeIP churn never causes a flash write.
NETSHIFT_CACHE_BACKUP="$NETSHIFT_STATE_DIR/cache.db"
NETSHIFT_CACHE_SELECTION="$NETSHIFT_STATE_DIR/cache.db.selection"
NETSHIFT_CACHE_BACKUP_LOCK="/var/lock/netshift-cache-backup.lock"
# Set when restore_sing_box_cache put a copy back into tmpfs on this boot. A copy
# sing-box then refuses to open would fail on every boot, because the copy lives
# on flash and is put back again each time; the monitor uses this flag to drop
# the restored cache once and let sing-box start clean instead. tmpfs on purpose:
# it only ever means "the cache running right now came from a copy".
NETSHIFT_CACHE_RESTORED_FLAG="/var/run/netshift-cache-restored"
RESOLV_CONF="/etc/resolv.conf"
DNS_RESOLVERS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 9.9.9.11 94.140.14.14 94.140.15.15 208.67.220.220 208.67.222.222 77.88.8.1 77.88.8.8"
CHECK_PROXY_IP_DOMAIN="ip.podkop.fyi"
FAKEIP_TEST_DOMAIN="fakeip.podkop.fyi"
TMP_SING_BOX_FOLDER="/tmp/sing-box"
TMP_RULESET_FOLDER="$TMP_SING_BOX_FOLDER/rulesets"
TMP_SUBSCRIPTION_FOLDER="$TMP_SING_BOX_FOLDER/subscriptions"
SUBSCRIPTION_CACHE_FOLDER="$NETSHIFT_STATE_DIR/subscriptions"
TMP_SUBSCRIPTION_DOWNLOAD_FOLDER="$TMP_SING_BOX_FOLDER/subscription-downloads"
# A section may list MULTIPLE subscription_url feeds. At config generation the
# usable per-URL caches are concatenated into one merged subscription JSON in
# this folder, then passed ONCE through the facade (keyword filter + global
# tag-dedup + sing-box check bisection). Per-feed cache files are keyed
# "${section}.<md5(url)>.<ext>" under SUBSCRIPTION_CACHE_FOLDER.
TMP_SUBSCRIPTION_MERGE_FOLDER="$TMP_SING_BOX_FOLDER/subscription-merge"
# Marks a subscription body that was downloaded into the cache but never made it
# into the running sing-box. The cache compares a feed against what is already
# stored, so without this marker the same body counts as "unchanged" on the next
# run and the router keeps serving the old outbounds. Set before any feed is
# downloaded. Lives in tmpfs on purpose: a reboot, and any start that builds a
# valid config, applies the cache anyway.
SUBSCRIPTION_PENDING_APPLY_FLAG="$TMP_SING_BOX_FOLDER/subscription-pending-apply"
# Seconds to wait after SIGHUP before deciding that sing-box came back up on the
# new config. Tests set it to 0.
SING_BOX_RELOAD_SETTLE_DELAY="3"
# Exit code of `netshift subscription_update` when the feeds were downloaded but
# applying them failed (the pending-apply marker stays for the next run).
SUBSCRIPTION_UPDATE_APPLY_FAILED=3
# Interval a subscription section runs on when its own
# `subscription_update_interval` says nothing usable: the option is absent (an
# old conffile), or it holds a value the cron table does not know (a hand-edited
# UCI option such as "2h"). An unknown value must NOT drop the section out of
# every cron job — that silently stops refreshing it — so it is treated as this
# default. Both the cron collector and the `subscription_update <interval>`
# section filter read this constant, so the two cannot drift apart silently.
SUBSCRIPTION_UPDATE_INTERVAL_DEFAULT="1h"
# Time of day (router local time, HH:MM) at which a "1d" subscription section is
# refreshed when its own `subscription_update_time` says nothing usable: the
# option is absent (every existing conffile) or is not a valid HH:MM. This is the
# time the daily job always ran at, so an upgrade keeps its schedule.
SUBSCRIPTION_UPDATE_TIME_DEFAULT="09:52"
# Deferred startup subscription refresh (start_subscription_startup_retry_worker):
# a feed that is unreachable is retried every SUBSCRIPTION_RETRY_INTERVAL
# seconds for as long as it takes. A feed that downloads but does not apply is
# retried with the wait doubling up to SUBSCRIPTION_RETRY_BACKOFF_MAX, and after
# SUBSCRIPTION_RETRY_MAX_APPLY_FAILURES such failures in a row the worker leaves
# it to the scheduled subscription update.
SUBSCRIPTION_RETRY_INTERVAL=30
SUBSCRIPTION_RETRY_MAX_APPLY_FAILURES=5
SUBSCRIPTION_RETRY_BACKOFF_MAX=600
# Subscription User-Agent fallback. Many panels return a DIFFERENT body format
# depending on the client User-Agent (sing-box JSON vs base64 URI list vs Clash
# vs Xray JSON, or an HTML/403 stub for unknown clients). When no User-Agent is
# configured for a source, the backend tries these candidates in order and
# keeps the first one that yields valid sing-box outbounds. The default
# "singbox/<version>" candidate is prepended at runtime (it depends on the
# installed sing-box). Order matters: most-likely-to-work first.
SUBSCRIPTION_USER_AGENT_CANDIDATES="v2rayN Happ Hiddify Clash.Meta ClashMetaForAndroid"
# Versioned client UAs that well-known panels answer with an Xray JSON body
# (which carries xhttp/transport nodes the default sing-box JSON may omit). Used
# by build_subscription_user_agent_candidates when a section's
# subscription_format_preference is "xray": these UAs are probed FIRST so an
# Xray-JSON feed is recovered before a sing-box JSON under the default UA wins.
# Panels commonly gate their Xray branch on a "<client>/<version>" UA shape, so
# these are VERSIONED (a bare/version-less UA can be rejected, e.g. with a 502).
# Order matters: a versioned Happ is first (empirically yields the Xray-JSON
# array body), then versioned v2rayN/v2rayNG forms as panel-agnostic fallbacks.
SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES="Happ/1.0.0 v2rayN/7.0.0 v2rayNG/1.9.0"
CLOUDFLARE_OCTETS="8.47 162.159 188.114" # Endpoints https://github.com/ampetelin/warp-endpoint-checker
JQ_REQUIRED_VERSION="1.7.1"
COREUTILS_BASE64_REQUIRED_VERSION="9.7"
RT_TABLE_NAME="netshift"
# Pidfile of the detached sing-box health monitor (task-035). The monitor is a
# long-lived `while true` loop launched via setsid with the procd lock fd (1000)
# closed, so it does NOT hold the procd service lock and consecutive
# reload/restart never block on flock. The monitor writes its own pid here.
MONITOR_PIDFILE="/var/run/netshift_monitor.pid"

## nft
NFT_TABLE_NAME="NetShiftTable"
NFT_LOCALV4_SET_NAME="localv4"
NFT_LOCALV6_SET_NAME="localv6"
# Destination set holding the UNION of every proxy section's proxied IPv4
# subnets (user/local/remote/community subnet lists). Used by the prerouting
# `mangle` chain to mark ONLY proxied destinations into the tproxy path, so
# non-proxied traffic (e.g. a torrent to a random direct IP) never enters
# sing-box (task-034). The per-section outbound is still selected by sing-box
# route rules — nft only decides enter-or-not, so a single union set is enough.
NFT_COMMON_SET_NAME="netshift_subnets"
# Destinations that bypass sing-box completely (exclusion sections with
# bypass_singbox): returned before any mark, so the traffic never enters tproxy.
NFT_BYPASS_SET_NAME="netshift_bypass"
NFT_BYPASS_SET_NAME_V6="netshift_bypass_v6"
# IPv6 mirror of NFT_COMMON_SET_NAME (only created/used when IPv6 is enabled).
NFT_COMMON_SET_NAME_V6="netshift_subnets_v6"
NFT_DISCORD_SET_NAME="netshift_discord_subnets"
NFT_INTERFACE_SET_NAME="interfaces"
NFT_FAKEIP_MARK="0x00100000"
NFT_OUTBOUND_MARK="0x00200000"

## LuCI
# Where the LuCI app keeps its views. The package installs them in a
# content-hashed view/netshift_<hash>/ (luci-app-netshift/cache-bust.sh); a
# hand-copied dev tree may still be view/netshift/.
LUCI_VIEW_DIR="/www/luci-static/resources/view"
LUCI_MENU_FILE="/usr/share/luci/menu.d/luci-app-netshift.json"

## sing-box
SB_REQUIRED_VERSION="1.12.0"
# First sing-box-extended release (the part after "-extended-") whose VLESS
# outbound has the `encryption` field; its pre-releases already carry it.
SB_EXTENDED_VLESS_ENCRYPTION_MIN="2.0.0"
# First sing-box-extended release whose Reality client has the
# `support_x25519mlkem768` option (it keeps the X25519MLKEM768 key share that
# REALITY servers on Xray-core >= 26.9.8 require). Older extended builds and
# stock sing-box do not know the field and would fail `sing-box check`.
SB_EXTENDED_REALITY_MLKEM_MIN="2.7.2"
# ── sing-box extended lite (third core variant) ─────────────────────
# Version suffix that marks a lite build: the release tag and the version
# banner of the binary are the upstream extended tag plus this suffix
# ("1.14.1-extended-2.7.2" -> "1.14.1-extended-2.7.2-lite").
SB_LITE_SUFFIX="-lite"
# Minimum effective free space (MB) on / for the pure ELF lite asset: at or
# above this the ELF build is chosen automatically, below it the
# UPX-compressed build (plus its wrapper) is the only one that fits.
SB_LITE_ELF_MIN_FLASH_MB=64
# Total RAM (MB) below which a UPX-compressed lite install reports the
# machine-readable warning code "upx_ram_spike": a UPX binary unpacks itself
# into memory at exec time, briefly needing more RAM than the process uses
# afterwards.
SB_LITE_RAM_WARN_MB=256
# Our fork's lite release repository. Tags mirror the shtorm-7 extended tags
# plus SB_LITE_SUFFIX; assets are
# sing-box-extended-lite-linux-<arch>[-compressed].tar.gz plus sha256sums.txt.
UPDATES_SING_BOX_LITE_REPO="yandexru45/sing-box-extended-lite"
# UPX lite layout: the compressed core binary lives here and /usr/bin/sing-box
# is a POSIX sh wrapper serving `version` from the snapshot cache below. The
# path deliberately matches the layout the community manual installs
# (MANCrimSon/EikeiDev) use, so those are detected and cleaned by the same
# code paths as ours.
UPDATES_SING_BOX_LITE_CORE_BIN="/usr/libexec/sing-box-core"
# Snapshot of the real `sing-box version` banner written at lite install
# time; the UPX wrapper cats it instead of unpacking the core for a mere
# version probe (and rebuilds it on demand when it is missing).
NETSHIFT_CORE_VERSION_CACHE="/etc/netshift/core-version.cache"
# Cache file a community manual lite install leaves behind (its wrapper reads
# it); removed as an artifact of leaving the lite variant.
UPDATES_SING_BOX_LITE_ORPHAN_CACHE="/etc/sing-box-version.cache"
# Monitoring
MONITOR_CHECK_INTERVAL=10
# How often the monitor looks for a server picked outside LuCI (Clash dashboard).
MONITOR_CACHE_SNAPSHOT_INTERVAL=60
# Priority node selection (section option priority_mode): how often the monitor
# re-checks the servers of such a section, and how long one latency probe may take.
PRIORITY_CHECK_INTERVAL_DEFAULT=30
PRIORITY_PROBE_TIMEOUT_MS=3000
PRIORITY_MAX_PROBES=10
# URL the probes use, and the time one check cycle may take in total (the monitor also
# supervises sing-box, so the cycle must not hold it for long).
PRIORITY_PROBE_URL="https://www.gstatic.com/generate_204"
PRIORITY_CYCLE_BUDGET=15
MONITOR_MAX_CRASHES=5
MONITOR_BACKOFF_BASE=10
MONITOR_BACKOFF_MAX=300
# Core-switch connectivity self-heal (task-009). Hosts probed before a core
# swap, depending on direction: the stable (stock) install pulls from the
# OpenWrt package feeds, the extended install pulls from the GitHub API.
UPDATES_FEED_PROBE_HOST="downloads.openwrt.org"
UPDATES_GITHUB_PROBE_HOST="api.github.com"
# Temporary public resolvers written to /etc/resolv.conf when DNS healing is
# needed (the user's upstream may itself be the now-dead VPN).
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
# tmpfs backup path for the original /etc/resolv.conf during a heal.
UPDATES_RESOLV_BACKUP="/tmp/netshift-resolv.conf.bak"
# Installed core paths (indirected so the stable backup/rollback path is unit
# testable without clobbering the real binary). These are the real on-device
# locations; tests override them.
UPDATES_SING_BOX_BIN="/usr/bin/sing-box"
UPDATES_LIBCRONET_LIB="/usr/lib/libcronet.so"
# apk world file; the stable reinstall from a package file restores the
# sing-box entry in it.
UPDATES_APK_WORLD="/etc/apk/world"
# mktemp template for the directory `apk fetch` downloads the stable sing-box
# package into. It deliberately sits on the same filesystem as the installed
# binary (overlay) instead of the tmpfs that holds the rollback backup.
UPDATES_APK_FETCH_DIR="/usr/lib/netshift/apk-fetch"
# Component Manager — NetShift self-update (task-017). The GitHub latest-release
# API for NetShift itself (same endpoint install.sh and get_system_info use);
# the self-update worker downloads the release .ipk/.apk assets from it.
NETSHIFT_RELEASE_API_URL="https://api.github.com/repos/yandexru45/netshift/releases/latest"
# GitHub FRONTEND (github.com, NOT the rate-limited api.github.com) redirect path
# for the NetShift repo. /releases/latest 302-redirects to /releases/tag/<tag>
# (resolve with curl -w '%{redirect_url}' — no API hit, not subject to the
# 60/hour/IP anonymous API limit); /releases/download/<tag>/<asset> 302s to the
# CDN for direct asset download. Primary path for version-check + self-update;
# NETSHIFT_RELEASE_API_URL stays as the graceful fallback. Repo slug lives here
# only — do not hardcode it elsewhere.
NETSHIFT_REPO_RELEASES_LATEST_URL="https://github.com/yandexru45/netshift/releases/latest"
NETSHIFT_REPO_RELEASES_DOWNLOAD_BASE="https://github.com/yandexru45/netshift/releases/download"
# tmpfs scratch dir for the self-update download (release packages) — RAM, never
# the tiny overlay; reaped on success and on reboot.
UPDATES_NETSHIFT_DOWNLOAD_DIR="/tmp/netshift/selfupdate"
# tmpfs backup of /etc/config/netshift taken before the self-update package
# install (conffiles normally preserve it; this is the defensive belt).
UPDATES_NETSHIFT_CONFIG_BACKUP="/tmp/netshift/config.bak"
# NetShift package names handled by the self-update (in install order). The RU
# i18n package is upgraded ONLY if already installed (never newly installed).
UPDATES_NETSHIFT_PKG_CORE="netshift"
UPDATES_NETSHIFT_PKG_LUCI="luci-app-netshift"
UPDATES_NETSHIFT_PKG_I18N_RU="luci-i18n-netshift-ru"
# DNS
SB_DNS_SERVER_TAG="dns-server"
# GeoIP country flags for subscription servers whose name has none
# (geoip_flags). Looked up once and kept in GEOIP_CACHE_FILE; a failed lookup
# is retried after GEOIP_NEGATIVE_TTL seconds, a found country after GEOIP_POSITIVE_TTL.
GEOIP_API_URL="https://api.country.is"
GEOIP_CACHE_FILE="$NETSHIFT_STATE_DIR/geoip.json"
GEOIP_LINKS_FILE="$TMP_SING_BOX_FOLDER/geoip-links.json"
GEOIP_POSITIVE_TTL=2592000
GEOIP_NEGATIVE_TTL=86400
GEOIP_BATCH_SIZE=100
GEOIP_MAX_HOSTS=300
# The name-resolving phase of a lookup stops after this many misses or seconds in total,
# so DNS that is down or slow cannot hold the config build for minutes.
GEOIP_RESOLVE_MAX_FAILURES=10
GEOIP_RESOLVE_BUDGET=60
# URL of the dashboard latency test (settings.latency_test_url overrides it)
LATENCY_TEST_URL_DEFAULT="https://www.gstatic.com/generate_204"
# Multi-DNS pool (issue #74): extra upstreams are "<SB_DNS_SERVER_TAG>-<n>" (n >= 2),
# the evaluated responses are tagged "<SB_DNS_POOL_RESPONSE_PREFIX><n>". It needs the
# DNS rule actions evaluate/respond/race that sing-box 1.14.0 introduced.
SB_DNS_POOL_RESPONSE_PREFIX="dns-pool-response-"
SB_DNS_EVALUATE_MIN="1.14.0"
DNS_POOL_TIMEOUT_DEFAULT="2s"
DNS_POOL_MAX_SERVERS=8
SB_FAKEIP_DNS_SERVER_TAG="fakeip-server"
SB_FAKEIP_INET4_RANGE="198.18.0.0/15"
SB_FAKEIP_INET6_RANGE="2001:2::/48"
SB_BOOTSTRAP_SERVER_TAG="bootstrap-dns-server"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"
# Sections with connection_type 'dns': their own DNS server / rule (per section name)
SB_SECTION_DNS_SERVER_PREFIX="dns-section-"
SB_SECTION_DNS_RULE_PREFIX="dns-section-rule-"
SB_INVERT_FAKEIP_DNS_RULE_TAG="invert-fakeip-dns-rule-tag"
# Inbounds
SB_TPROXY_INBOUND_TAG="tproxy-in"
SB_TPROXY_INBOUND_ADDRESS="127.0.0.1"
SB_TPROXY_INBOUND_PORT=1602
SB_TPROXY_INBOUND_ADDRESS_V6="::1"
SB_TPROXY_INBOUND_PORT_V6=1603
SB_DNS_INBOUND_TAG="dns-in"
SB_DNS_INBOUND_ADDRESS="127.0.0.42"
SB_DNS_INBOUND_PORT=53
SB_DNS_INBOUND_ADDRESS_V6="::1"
SB_DNS_INBOUND_PORT_V6=5354
SB_SERVICE_MIXED_INBOUND_TAG="service-mixed-in"
SB_SERVICE_MIXED_INBOUND_ADDRESS="127.0.0.1"
SB_SERVICE_MIXED_INBOUND_PORT=4534
# Outbounds
SB_DIRECT_OUTBOUND_TAG="direct-out"
# Subscription grouping (task-044). Default codepoint count for prefix-mode
# grouping when subscription_group_prefix_len is unset/invalid.
SUBSCRIPTION_GROUP_DEFAULT_PREFIX_LEN=2
# Subscription grouping (task-050). Tag/label for the top-level "Fastest"
# urltest that probes ACROSS the per-group urltests (a urltest of urltests)
# when grouping is on. Valid UTF-8 emoji + English; deliberately distinct from
# a per-group "<flag> Fastest" tag so the cross-group auto choice is tellable
# apart in the dashboard. Single source for the tag (keep this file UTF-8).
SB_SUBSCRIPTION_FASTEST_GROUP_TAG="⚡ Fastest"
# Several subscription_url in one section (group mode off): every feed that
# contributes nodes gets its own urltest tagged "<prefix><feed name>" next to
# the section-wide one, so the dashboard can show a Fastest per subscription.
SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX="⚡ "
# Key stamped on every merged subscription node with its feed index (position
# in the section's subscription_url list). The facade strips it before the
# node reaches the config and reports it as SUBSCRIPTION_OUTBOUND_FEEDS_JSON.
SUBSCRIPTION_FEED_MARKER_KEY="_netshift_feed"
# Route
SB_REJECT_RULE_TAG="reject-rule-tag"
SB_EXCLUSION_RULE_TAG="exclusion-rule-tag"
SB_DOH_BLOCK_RULE_TAG="doh-block-rule-tag"
SB_BITTORRENT_DIRECT_RULE_TAG="bittorrent-direct-rule-tag"
# Experimental
SB_CLASH_API_CONTROLLER_PORT=9090

## DoH blocking
DOH_BLOCK_IPV4_CIDRS="1.1.1.1/32 1.0.0.1/32 8.8.8.8/32 8.8.4.4/32 9.9.9.9/32 9.9.9.11/32 149.112.112.112/32 208.67.222.222/32 208.67.220.220/32 94.140.14.14/32 94.140.15.15/32 77.88.8.8/32 77.88.8.1/32"
DOH_BLOCK_IPV6_CIDRS="2606:4700:4700::1111/128 2606:4700:4700::1001/128 2001:4860:4860::8888/128 2001:4860:4860::8844/128 2620:fe::fe/128 2620:fe::9/128 2620:119:35::35/128 2620:119:53::53/128 2a10:50c0::ad1:ff/128 2a10:50c0::ad2:ff/128 2a02:6b8::feed:0ff/128 2a02:6b8:0:1::feed:0ff/128"

## Lists
GITHUB_RAW_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main"
SRS_MAIN_URL="https://github.com/itdoginfo/allow-domains/releases/latest/download"
SUBNETS_TWITTER="${GITHUB_RAW_URL}/Subnets/IPv4/twitter.lst"
SUBNETS_META="${GITHUB_RAW_URL}/Subnets/IPv4/meta.lst"
SUBNETS_DISCORD="${GITHUB_RAW_URL}/Subnets/IPv4/discord.lst"
SUBNETS_ROBLOX="${GITHUB_RAW_URL}/Subnets/IPv4/roblox.lst"
SUBNETS_TELERAM="${GITHUB_RAW_URL}/Subnets/IPv4/telegram.lst"
SUBNETS_CLOUDFLARE="${GITHUB_RAW_URL}/Subnets/IPv4/cloudflare.lst"
SUBNETS_HETZNER="${GITHUB_RAW_URL}/Subnets/IPv4/hetzner.lst"
SUBNETS_OVH="${GITHUB_RAW_URL}/Subnets/IPv4/ovh.lst"
SUBNETS_DIGITALOCEAN="${GITHUB_RAW_URL}/Subnets/IPv4/digitalocean.lst"
SUBNETS_CLOUDFRONT="${GITHUB_RAW_URL}/Subnets/IPv4/cloudfront.lst"
COMMUNITY_SERVICES="russia_inside russia_outside ukraine_inside geoblock block porn news anime youtube hdrezka tiktok google_ai google_play hodca discord meta twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox"

# Environment hints (check_environment): a clock earlier than this (2025-01-01) is
# certainly not the real time, and the response header of this URL is compared
# with the router clock.
ENVIRONMENT_MIN_PLAUSIBLE_EPOCH=1735689600
ENVIRONMENT_CLOCK_PROBE_URL="https://www.cloudflare.com/"

# Pin guard (pinguard.sh): failed probes in a row before a pinned server is given up,
# and how many switches are kept for the dashboard.
PIN_GUARD_FAILURES=3
PIN_GUARD_EVENTS_FILE="/tmp/netshift-pin-guard.json"
PIN_GUARD_EVENTS_KEEP=10
