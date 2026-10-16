// What the installed sing-box core can do (netshift get_core_capabilities), so that
// the pages do not offer what it cannot carry. Until the answer is in (or when it
// cannot be read) every feature counts as available: the backend skips a link or
// a server the core cannot carry anyway, and a wrong refusal here would block a
// setup that works.

export interface CoreCapabilities {
  version: string;
  variant: string;
  quic: boolean;
  utls: boolean;
  naive: boolean;
  naive_core: boolean;
  naive_client: boolean;
  dns_pool: boolean;
  extended: boolean;
  vmess: boolean;
  xhttp: boolean;
  vless_encryption: boolean;
  reality_mlkem: boolean;
}

export const UNKNOWN_CORE_CAPABILITIES: CoreCapabilities = {
  version: '',
  variant: 'stock',
  quic: true,
  utls: true,
  naive: true,
  naive_core: false,
  naive_client: false,
  dns_pool: true,
  extended: true,
  vmess: true,
  xhttp: true,
  vless_encryption: true,
  reality_mlkem: true,
};

export function parseCoreCapabilities(input: unknown): CoreCapabilities {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return { ...UNKNOWN_CORE_CAPABILITIES };
    }
  }

  if (!data || typeof data !== 'object') {
    return { ...UNKNOWN_CORE_CAPABILITIES };
  }

  const value = data as Record<string, unknown>;
  const flag = (key: keyof CoreCapabilities) =>
    typeof value[key] === 'boolean'
      ? (value[key] as boolean)
      : (UNKNOWN_CORE_CAPABILITIES[key] as boolean);

  return {
    version: typeof value.version === 'string' ? value.version : '',
    variant: typeof value.variant === 'string' ? value.variant : 'stock',
    quic: flag('quic'),
    utls: flag('utls'),
    naive: flag('naive'),
    naive_core: flag('naive_core'),
    naive_client: flag('naive_client'),
    dns_pool: flag('dns_pool'),
    extended: flag('extended'),
    vmess: flag('vmess'),
    xhttp: flag('xhttp'),
    vless_encryption: flag('vless_encryption'),
    reality_mlkem: flag('reality_mlkem'),
  };
}

let current: CoreCapabilities = { ...UNKNOWN_CORE_CAPABILITIES };

export function setCoreCapabilities(value: CoreCapabilities) {
  current = value;
}

export function getCoreCapabilities(): CoreCapabilities {
  return current;
}
