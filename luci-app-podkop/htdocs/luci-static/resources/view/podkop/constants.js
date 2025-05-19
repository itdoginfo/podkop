'use strict';
'require baseclass';

const STATUS_COLORS = {
    SUCCESS: '#4caf50',
    ERROR: '#f44336',
    WARNING: '#ff9800'
};

const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
const IP_CHECK_DOMAIN = 'ip.podkop.fyi';

const REGIONAL_OPTIONS = ['russia_inside', 'russia_outside', 'ukraine_inside'];
const ALLOWED_WITH_RUSSIA_INSIDE = [
    'russia_inside',
    'meta',
    'twitter',
    'discord',
    'telegram',
    'cloudflare',
    'google_ai',
    'google_play',
    'hetzner',
    'ovh'
];

const DOMAIN_LIST_OPTIONS = {
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
    hetzner: 'Hetzner ASN',
    ovh: 'OVH ASN'
};

const UPDATE_INTERVAL_OPTIONS = {
    '1h': 'Every hour',
    '3h': 'Every 3 hours',
    '12h': 'Every 12 hours',
    '1d': 'Every day',
    '3d': 'Every 3 days'
};

const DNS_SERVER_OPTIONS = {
    '1.1.1.1': 'Cloudflare (1.1.1.1)',
    '8.8.8.8': 'Google (8.8.8.8)',
    '9.9.9.9': 'Quad9 (9.9.9.9)',
    'dns.adguard-dns.com': 'AdGuard Default (dns.adguard-dns.com)',
    'unfiltered.adguard-dns.com': 'AdGuard Unfiltered (unfiltered.adguard-dns.com)',
    'family.adguard-dns.com': 'AdGuard Family (family.adguard-dns.com)'
};

const DIAGNOSTICS_UPDATE_INTERVAL = 10000; // 10 seconds
const CACHE_TIMEOUT = DIAGNOSTICS_UPDATE_INTERVAL - 1000; // 9 seconds
const ERROR_POLL_INTERVAL = 10000; // 10 seconds
const COMMAND_TIMEOUT = 10000; // 10 seconds
const FETCH_TIMEOUT = 10000; // 10 seconds
const BUTTON_FEEDBACK_TIMEOUT = 1000; // 1 second
const DIAGNOSTICS_INITIAL_DELAY = 100; // 100 milliseconds

// Массив задержек для приоритетов выполнения команд в диагностике (в миллисекундах)
const RUN_PRIORITY = [
    0,      // Приоритет 0 - Критический (выполняется немедленно)
    100,    // Приоритет 1 - Очень высокий
    300,    // Приоритет 2 - Высокий
    500,    // Приоритет 3 - Выше среднего
    700,    // Приоритет 4 - Средний
    900,    // Приоритет 5 - Ниже среднего
    1100,   // Приоритет 6 - Низкий
    1300,   // Приоритет 7 - Очень низкий
    1500,   // Приоритет 8 - Фоновый
    1700,   // Приоритет 9 - Отложенный
    1900    // Приоритет 10 - Наименее важный
];

return baseclass.extend({
    STATUS_COLORS,
    FAKEIP_CHECK_DOMAIN,
    IP_CHECK_DOMAIN,
    REGIONAL_OPTIONS,
    ALLOWED_WITH_RUSSIA_INSIDE,
    DOMAIN_LIST_OPTIONS,
    UPDATE_INTERVAL_OPTIONS,
    DNS_SERVER_OPTIONS,
    DIAGNOSTICS_UPDATE_INTERVAL,
    ERROR_POLL_INTERVAL,
    COMMAND_TIMEOUT,
    FETCH_TIMEOUT,
    BUTTON_FEEDBACK_TIMEOUT,
    DIAGNOSTICS_INITIAL_DELAY,
    RUN_PRIORITY,
    CACHE_TIMEOUT
});
