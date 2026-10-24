// A believable client identity for a subscription request: what Happ or INCY on a
// given platform sends in User-Agent, X-HWID, X-Device-OS, X-Ver-OS and
// X-Device-Model. The formats and values are the most common ones a Remnawave
// panel recorded from its devices active in October 2026.

export interface ClientIdentity {
  user_agent: string;
  hwid: string;
  device_os: string;
  os_version: string;
  device_model: string;
}

type Random = () => number;

const HEX = '0123456789abcdef';
const ALNUM = '0123456789abcdefghijklmnopqrstuvwxyz';
const DIGITS = '0123456789';
const HOST = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

function chars(alphabet: string, length: number, random: Random): string {
  let out = '';

  for (let i = 0; i < length; i++) {
    out += alphabet[Math.floor(random() * alphabet.length)];
  }

  return out;
}

function pick<T>(list: T[], random: Random): T {
  return list[Math.floor(random() * list.length)];
}

function uuid(random: Random): string {
  const hex = chars(HEX, 32, random);

  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    '4' + hex.slice(13, 16),
    '89ab'[Math.floor(random() * 4)] + hex.slice(17, 20),
    hex.slice(20, 32),
  ].join('-');
}

// {install}: the 20-digit number Happ on Android adds per install;
// {host}: the random part of a default Windows computer name.
function fill(template: string, random: Random): string {
  return template
    .replace(
      '{install}',
      () => chars('123456789', 1, random) + chars(DIGITS, 19, random),
    )
    .replace('{host}', () => chars(HOST, 7, random));
}

interface Profile {
  hwid: (random: Random) => string;
  deviceOs: string;
  // [User-Agent, OS version]: on Apple systems the Darwin version in the
  // User-Agent goes with the OS version, so they are picked as a pair.
  variants: [string, string][];
  models: string[];
}

// What the panel's devices show: Happ on Android sends the 64-bit Android ID
// (16 hex), on Apple systems 16 random base36 characters, on Windows a random
// UUID v4. INCY sends a SHA-256 of the device cut to the UUID layout: upper
// case, with no version or variant digit, so it is not made with uuid().
const happHwid = (random: Random) => chars(HEX, 16, random);
const happAppleHwid = (random: Random) => chars(ALNUM, 16, random);
const incyHwid = (random: Random) =>
  chars(HEX, 32, random)
    .toUpperCase()
    .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');

const ANDROID_MODELS = [
  'CPH2747',
  'SM-A556E',
  'SM-S721B',
  'SM-S938B',
  'SM-S918N',
  '2112123AG',
];
const IPHONE_MODELS = [
  'iPhone 15 Pro Max',
  'iPhone 16 Pro Max',
  'iPhone 17 Pro',
  'iPhone 13',
  'iPhone 16',
  'iPhone 15 Pro',
];

export const CLIENT_IDENTITY_PROFILES: Record<
  string,
  Record<string, Profile>
> = {
  Happ: {
    Android: {
      hwid: happHwid,
      deviceOs: 'Android',
      variants: ['16', '15', '14', '13'].map((version) => [
        'Happ/4.7.1/Android/{install}',
        version,
      ]),
      models: ANDROID_MODELS,
    },
    AndroidTV: {
      hwid: happHwid,
      deviceOs: 'AndroidTV',
      variants: ['14', '12', '11'].map((version) => [
        'Happ/4.7.1/AndroidTV/{install}',
        version,
      ]),
      models: ['MiTV-MOOQ1', 'MiTV-AFKR0', 'VONTAR H618', '4K PA Google TV'],
    },
    iOS: {
      hwid: happAppleHwid,
      deviceOs: 'iOS',
      variants: ['26.6.2', '26.6.1', '27.0.1'].map((version) => [
        'Happ/6.1.0/ios/2610091516618',
        version,
      ]),
      models: IPHONE_MODELS,
    },
    macOS: {
      hwid: happAppleHwid,
      deviceOs: 'macOS',
      variants: ['27.0.1', '26.6.2', '15.7.9'].map((version) => [
        'Happ/6.1.0/macos catalyst/2610091518671',
        version,
      ]),
      models: ['Mac', 'MacBook', 'iMac'],
    },
    Windows: {
      hwid: uuid,
      deviceOs: 'Windows',
      variants: ['11_10.0.26200', '10_10.0.19045', '11_10.0.26100'].map(
        (version) => ['Happ/4.5.4/Windows/2610141139602', version],
      ),
      models: ['DESKTOP-{host}_x86_64'],
    },
  },
  INCY: {
    Android: {
      hwid: incyHwid,
      deviceOs: 'Android',
      variants: ['16', '15', '14', '13'].map((version) => [
        'INCY/3.7.9/android Dalvik/2.1.0',
        version,
      ]),
      models: [
        'samsung SM-S938B',
        'samsung SM-A546E',
        'samsung SM-A556E',
        'Xiaomi 24116RACCG',
        'Xiaomi 2311DRK48G',
      ],
    },
    iOS: {
      hwid: incyHwid,
      deviceOs: 'iOS',
      variants: [
        ['INCY/2.6.4/ios CFNetwork/3896.100.1.2.1 Darwin/27.0.0', '27.0.1'],
        ['INCY/2.6.4/ios CFNetwork/3860.700.2 Darwin/25.6.0', '26.6.2'],
        ['INCY/2.6.4/ios CFNetwork/3860.700.2 Darwin/25.6.0', '26.6.1'],
      ],
      models: IPHONE_MODELS,
    },
    'Mac OS X': {
      hwid: incyHwid,
      deviceOs: 'Mac OS X',
      variants: [
        ['INCY/3.8.8/mac os x Dalvik/21.0.11+10-LTS', '26.6.2'],
        ['INCY/3.8.8/mac os x Dalvik/21.0.11+10-LTS', '15.3.1'],
      ],
      models: ['Mac OS X aarch64'],
    },
    'Windows 11': {
      hwid: incyHwid,
      deviceOs: 'Windows 11',
      variants: [['INCY/3.9.0/windows 11 Dalvik/21.0.12+8-LTS', '10.0']],
      models: ['Windows 11 amd64'],
    },
    'Windows 10': {
      hwid: incyHwid,
      deviceOs: 'Windows 10',
      variants: [['INCY/3.8.10/windows 10 Dalvik/21.0.12+8-LTS', '10.0']],
      models: ['Windows 10 amd64'],
    },
  },
};

export function generateClientIdentity(
  app: string,
  platform: string,
  random: Random = Math.random,
): ClientIdentity | null {
  const profile = CLIENT_IDENTITY_PROFILES[app]?.[platform];

  if (!profile) {
    return null;
  }

  const [userAgent, osVersion] = pick(profile.variants, random);

  return {
    user_agent: fill(userAgent, random),
    hwid: profile.hwid(random),
    device_os: profile.deviceOs,
    os_version: osVersion,
    device_model: fill(pick(profile.models, random), random),
  };
}
