# shellcheck shell=ash
# shellcheck disable=SC2034

NETSHIFT_VERSION="__COMPILED_VERSION_VARIABLE__"
## Common
NETSHIFT_CONFIG="/etc/config/netshift"
NETSHIFT_STATE_DIR="/etc/netshift"
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
# IPv6 mirror of NFT_COMMON_SET_NAME (only created/used when IPv6 is enabled).
NFT_COMMON_SET_NAME_V6="netshift_subnets_v6"
NFT_DISCORD_SET_NAME="netshift_discord_subnets"
NFT_INTERFACE_SET_NAME="interfaces"
NFT_FAKEIP_MARK="0x00100000"
NFT_OUTBOUND_MARK="0x00200000"

## sing-box
SB_REQUIRED_VERSION="1.12.0"
# Monitoring
MONITOR_CHECK_INTERVAL=10
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
SB_FAKEIP_DNS_SERVER_TAG="fakeip-server"
SB_FAKEIP_INET4_RANGE="198.18.0.0/15"
SB_FAKEIP_INET6_RANGE="fd00:ec3a::/32"
SB_BOOTSTRAP_SERVER_TAG="bootstrap-dns-server"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"
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
# Route
SB_REJECT_RULE_TAG="reject-rule-tag"
SB_EXCLUSION_RULE_TAG="exclusion-rule-tag"
SB_DOH_BLOCK_RULE_TAG="doh-block-rule-tag"
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
