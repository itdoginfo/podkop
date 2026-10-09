// The Settings page shows the main DNS server and the additional ones as ONE
// ordered list: the first entry is the main server, the rest are the pool.
// The stored options stay as they were (dns_type + dns_server for the main one,
// the dns_pool_server list for the others), so older configs open as they are,
// nothing needs migrating, and a downgrade keeps working. These helpers convert
// between the list shown and those options.

export interface DnsServerOptions {
  dns_type: string;
  dns_server: string;
  dns_pool_server: string[];
}

const SCHEMES = ['udp', 'tcp', 'dot', 'doh', 'doh3', 'doq'];

// Defaults the backend uses for an option that is not set.
export const DEFAULT_DNS_TYPE = 'udp';
export const DEFAULT_DNS_SERVER = '8.8.8.8';

export function dnsServersFromOptions(
  options: Partial<DnsServerOptions>,
): string[] {
  const type = options.dns_type || DEFAULT_DNS_TYPE;
  const server = options.dns_server || DEFAULT_DNS_SERVER;
  const pool = (options.dns_pool_server ?? [])
    .map((entry) => entry.trim())
    .filter(Boolean);

  return [`${type}://${server}`, ...pool];
}

// The first entry becomes the main server, the others the pool. Returns null
// when the first entry is not a scheme://address one (the form validates this
// before saving, so it only guards against bad input).
export function dnsServersToOptions(list: string[]): DnsServerOptions | null {
  const entries = list.map((entry) => entry.trim()).filter(Boolean);

  if (entries.length === 0) {
    return null;
  }

  const [first, ...rest] = entries;
  const separator = first.indexOf('://');

  if (separator < 0) {
    return null;
  }

  const scheme = first.slice(0, separator);
  const server = first.slice(separator + 3);

  if (!SCHEMES.includes(scheme) || !server) {
    return null;
  }

  return { dns_type: scheme, dns_server: server, dns_pool_server: rest };
}
