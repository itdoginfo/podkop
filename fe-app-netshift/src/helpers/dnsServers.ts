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

// How one DNS server is reached: "direct", "tunnel" (the DNS outbound section,
// the older spelling) or "via:<section>" (through that section's outbound).
export type DnsServerRoute = string;

export const DNS_ROUTE_DIRECT = 'direct';
export const DNS_ROUTE_TUNNEL = 'tunnel';
export const DNS_ROUTE_VIA_PREFIX = 'via:';

export function dnsRouteVia(section: string): DnsServerRoute {
  return `${DNS_ROUTE_VIA_PREFIX}${section}`;
}

// The section of a "via:<section>" route, or null for any other route.
export function dnsRouteSection(route: DnsServerRoute): string | null {
  return route.startsWith(DNS_ROUTE_VIA_PREFIX) && route.length > 4
    ? route.slice(DNS_ROUTE_VIA_PREFIX.length)
    : null;
}

function isKnownRoute(route: string): boolean {
  return (
    route === DNS_ROUTE_DIRECT ||
    route === DNS_ROUTE_TUNNEL ||
    dnsRouteSection(route) !== null
  );
}

// dns_server_route holds "<server> <route>" entries (<server> is written as in
// the server list); a server without an entry follows the global switch
// (dns_via_outbound), which the page turns into an explicit route.
export function dnsRoutesFromOptions(
  entries: string[],
): Record<string, DnsServerRoute> {
  const routes: Record<string, DnsServerRoute> = {};

  entries.forEach((entry) => {
    const text = entry.trim();
    const split = text.lastIndexOf(' ');

    if (split < 0) {
      return;
    }

    const server = text.slice(0, split).trim();
    const route = text.slice(split + 1);

    if (server && isKnownRoute(route)) {
      routes[server] = route;
    }
  });

  return routes;
}

// The entries to store for the servers of the list, in list order: the ones whose
// route differs from what the backend assumes without an entry (`backendDefault`:
// "direct", or "tunnel" while the old global switch is on). A config where every
// server is direct and the switch is off stays free of entries.
export function dnsRoutesToOptions(
  servers: string[],
  routes: Record<string, DnsServerRoute>,
  backendDefault: DnsServerRoute = DNS_ROUTE_DIRECT,
): string[] {
  return servers
    .map((server) => server.trim())
    .filter((server, index, all) => server && all.indexOf(server) === index)
    .filter((server) => {
      const route = routes[server];

      return route && isKnownRoute(route) && route !== backendDefault;
    })
    .map((server) => `${server} ${routes[server]}`);
}

// The setting that makes a proxy section "configured", by its proxy_config_type
// (the backend's section_has_configured_outbound).
const PROXY_LINK_OPTION: Record<string, string> = {
  url: 'proxy_string',
  selector: 'selector_proxy_links',
  urltest: 'urltest_proxy_links',
  selector_text: 'selector_proxy_links_text',
  urltest_text: 'urltest_proxy_links_text',
  outbound: 'outbound_json',
  subscription: 'subscription_url',
};

function isFilled(value: unknown): boolean {
  return Array.isArray(value) ? value.length > 0 : Boolean(value);
}

// Can a DNS server be sent through this section? The same answer as the backend's
// section_has_configured_outbound: not disabled, and the setting of its type filled in
// (a link, a list of links, an outbound, a subscription address, an interface). A section
// that is only half set up is turned down by the backend, which then sends the server
// directly, so the table must not offer it.
export function isConfiguredOutboundSection(
  section: Record<string, unknown>,
): boolean {
  if (section.disabled === '1') {
    return false;
  }

  if (section.connection_type === 'vpn') {
    return isFilled(section.interface);
  }

  if (section.connection_type === 'proxy') {
    const option =
      PROXY_LINK_OPTION[String(section.proxy_config_type || 'url')];

    return Boolean(option) && isFilled(section[option]);
  }

  return false;
}
