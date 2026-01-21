export const STATUS_COLORS = {
  SUCCESS: '#4caf50',
  ERROR: '#f44336',
  WARNING: '#ff9800',
};

export const PODKOP_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
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

export const DNS_SERVER_OPTIONS = {
  '1.1.1.1': '1.1.1.1 (Cloudflare)',
  '8.8.8.8': '8.8.8.8 (Google)',
  '9.9.9.9': '9.9.9.9 (Quad9)',
  'dns.adguard-dns.com': 'dns.adguard-dns.com (AdGuard Default)',
  'unfiltered.adguard-dns.com':
    'unfiltered.adguard-dns.com (AdGuard Unfiltered)',
  'family.adguard-dns.com': 'family.adguard-dns.com (AdGuard Family)',
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
};

export const DIAGNOSTICS_UPDATE_INTERVAL = 10000; // 10 seconds
export const CACHE_TIMEOUT = DIAGNOSTICS_UPDATE_INTERVAL - 1000; // 9 seconds
export const ERROR_POLL_INTERVAL = 10000; // 10 seconds
export const COMMAND_TIMEOUT = 10000; // 10 seconds
export const FETCH_TIMEOUT = 10000; // 10 seconds
export const BUTTON_FEEDBACK_TIMEOUT = 1000; // 1 second
export const DIAGNOSTICS_INITIAL_DELAY = 100; // 100 milliseconds

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
