export const STATUS_COLORS = {
  SUCCESS: '#4caf50',
  ERROR: '#f44336',
  WARNING: '#ff9800',
};

export const NETSHIFT_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';

export const REGIONAL_OPTIONS = [
  'russia_inside',
  'russia_outside',
  'ukraine_inside',
];

export const ALLOWED_WITH_RUSSIA_INSIDE = [
  'russia_inside',
  'meta',
  'twitter',
  'discord',
  'telegram',
  'cloudflare',
  'google_ai',
  'google_play',
  'hetzner',
  'ovh',
  'hodca',
  'roblox',
  'digitalocean',
  'cloudfront',
];

export const DOMAIN_LIST_OPTIONS = {
  russia_inside: 'Russia inside',
  russia_outside: 'Russia outside',
  ukraine_inside: 'Ukraine',
  geoblock: 'Geo Block',
  block: 'Block',
  porn: 'Porn',
  news: 'News',
  anime: 'Anime',
  youtube: 'Youtube',
  discord: 'Discord',
  meta: 'Meta',
  twitter: 'Twitter (X)',
  hdrezka: 'HDRezka',
  tiktok: 'Tik-Tok',
  telegram: 'Telegram',
  cloudflare: 'Cloudflare',
  google_ai: 'Google AI',
  google_play: 'Google Play',
  hodca: 'H.O.D.C.A',
  roblox: 'Roblox',
  hetzner: 'Hetzner ASN',
  ovh: 'OVH ASN',
  digitalocean: 'Digital Ocean ASN',
  cloudfront: 'CloudFront ASN',
};

export const UPDATE_INTERVAL_OPTIONS = {
  '1h': 'Every hour',
  '3h': 'Every 3 hours',
  '12h': 'Every 12 hours',
  '1d': 'Every day',
  '3d': 'Every 3 days',
};

export const SUBSCRIPTION_UPDATE_INTERVAL_OPTIONS = {
  '30m': 'Every 30 minutes',
  '1h': 'Every hour',
  '3h': 'Every 3 hours',
  '6h': 'Every 6 hours',
  '12h': 'Every 12 hours',
  '1d': 'Every day',
};

export const DNS_SERVER_OPTIONS = {
  '1.1.1.1': '1.1.1.1 (Cloudflare)',
  '8.8.8.8': '8.8.8.8 (Google)',
  '9.9.9.9': '9.9.9.9 (Quad9)',
  'dns.adguard-dns.com': 'dns.adguard-dns.com (AdGuard Default)',
  'unfiltered.adguard-dns.com':
    'unfiltered.adguard-dns.com (AdGuard Unfiltered)',
  'family.adguard-dns.com': 'family.adguard-dns.com (AdGuard Family)',
  '2001:4860:4860::8888': '2001:4860:4860::8888 (Google IPv6)',
  '2606:4700:4700::1111': '2606:4700:4700::1111 (Cloudflare IPv6)',
  '2620:fe::fe': '2620:fe::fe (Quad9 IPv6)',
};
// Ready-made entries for the additional DNS servers (dns_pool_server), one per
// transport the pool understands. The list accepts any other scheme://host too.
export const DNS_POOL_PRESETS = {
  'udp://8.8.8.8': 'Google - UDP (8.8.8.8)',
  'tcp://8.8.8.8': 'Google - TCP (8.8.8.8)',
  'dot://dns.google': 'Google - DoT (dns.google)',
  'doh://dns.google/dns-query': 'Google - DoH (dns.google)',
  'doh3://dns.google/dns-query': 'Google - DoH3 (dns.google)',
  'udp://1.1.1.1': 'Cloudflare - UDP (1.1.1.1)',
  'tcp://1.1.1.1': 'Cloudflare - TCP (1.1.1.1)',
  'dot://one.one.one.one': 'Cloudflare - DoT (one.one.one.one)',
  'doh://cloudflare-dns.com/dns-query': 'Cloudflare - DoH (cloudflare-dns.com)',
  'doh3://cloudflare-dns.com/dns-query':
    'Cloudflare - DoH3 (cloudflare-dns.com)',
  'udp://9.9.9.9': 'Quad9 - UDP (9.9.9.9)',
  'dot://dns.quad9.net': 'Quad9 - DoT (dns.quad9.net)',
  'doh://dns.quad9.net/dns-query': 'Quad9 - DoH (dns.quad9.net)',
  'udp://94.140.14.14': 'AdGuard - UDP (94.140.14.14)',
  'dot://dns.adguard-dns.com': 'AdGuard - DoT (dns.adguard-dns.com)',
  'doh://dns.adguard-dns.com/dns-query': 'AdGuard - DoH (dns.adguard-dns.com)',
  'doh3://dns.adguard-dns.com/dns-query':
    'AdGuard - DoH3 (dns.adguard-dns.com)',
  'doq://dns.adguard-dns.com': 'AdGuard - DoQ (dns.adguard-dns.com)',
  'udp://77.88.8.8': 'Yandex - UDP (77.88.8.8)',
  'dot://common.dot.dns.yandex.net': 'Yandex - DoT (common.dot.dns.yandex.net)',
  'doh://common.dns.yandex.net/dns-query':
    'Yandex - DoH (common.dns.yandex.net)',
  'dot://dns.mullvad.net': 'Mullvad - DoT (dns.mullvad.net)',
  'doh://dns.mullvad.net/dns-query': 'Mullvad - DoH (dns.mullvad.net)',
};
export const BOOTSTRAP_DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '77.88.8.1': '77.88.8.1 (Yandex DNS)',
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '9.9.9.11': '9.9.9.11 (Quad9 DNS)',
  '2001:4860:4860::8888': '2001:4860:4860::8888 (Google DNS IPv6)',
  '2606:4700:4700::1111': '2606:4700:4700::1111 (Cloudflare DNS IPv6)',
};

export const DIAGNOSTICS_UPDATE_INTERVAL = 10000; // 10 seconds
export const CACHE_TIMEOUT = DIAGNOSTICS_UPDATE_INTERVAL - 1000; // 9 seconds
export const ERROR_POLL_INTERVAL = 10000; // 10 seconds
export const COMMAND_TIMEOUT = 10000; // 10 seconds
export const FETCH_TIMEOUT = 10000; // 10 seconds
export const BUTTON_FEEDBACK_TIMEOUT = 1000; // 1 second
export const DIAGNOSTICS_INITIAL_DELAY = 100; // 100 milliseconds
export const SKELETON_SHIMMER_DURATION = 1600; // 1.6 seconds

// Command scheduling intervals in diagnostics (in milliseconds)
export const COMMAND_SCHEDULING = {
  P0_PRIORITY: 0, // Highest priority (no delay)
  P1_PRIORITY: 100, // Very high priority
  P2_PRIORITY: 300, // High priority
  P3_PRIORITY: 500, // Above average
  P4_PRIORITY: 700, // Standard priority
  P5_PRIORITY: 900, // Below average
  P6_PRIORITY: 1100, // Low priority
  P7_PRIORITY: 1300, // Very low priority
  P8_PRIORITY: 1500, // Background execution
  P9_PRIORITY: 1700, // Idle mode execution
  P10_PRIORITY: 1900, // Lowest priority
} as const;
