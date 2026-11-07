// The Devices page lists the clients the router knows about. The router also
// "sees" addresses that are not LAN devices: the provider's neighbours on the
// WAN side show up in the neighbour table too. The backend reports the LAN
// subnets and the static DHCP leases (netshift get_lan_info); these helpers
// decide what is a LAN device and shape the answers.

export interface StaticLease {
  section: string;
  macs: string[];
  ip: string;
  name: string;
}

export interface LanInfo {
  subnets: string[];
  staticHosts: StaticLease[];
}

export const EMPTY_LAN_INFO: LanInfo = { subnets: [], staticHosts: [] };

export interface LanDeviceAddress {
  ip: string;
  mac: string;
  name: string;
  offline?: boolean;
}

export interface LanDevice extends LanDeviceAddress {
  addresses: string[];
}

export function groupDeviceAddresses(entries: LanDeviceAddress[]): LanDevice[] {
  const groups = new Map<string, LanDevice>();

  for (const entry of entries) {
    const key = entry.mac ? `mac:${entry.mac.toUpperCase()}` : `ip:${entry.ip}`;
    const group = groups.get(key);

    if (!group) {
      groups.set(key, {
        ...entry,
        addresses: [entry.ip],
        offline: !!entry.offline,
      });
      continue;
    }

    if (!group.addresses.includes(entry.ip)) {
      group.addresses.push(entry.ip);
    }

    group.name ||= entry.name;
    group.offline = group.offline && !!entry.offline;
  }

  return [...groups.values()].map((group) => {
    group.addresses = [
      ...group.addresses.filter((ip) => ipv4ToNumber(ip) !== null),
      ...group.addresses.filter((ip) => ipv4ToNumber(ip) === null),
    ];
    group.ip = group.addresses[0];
    return group;
  });
}

function ipv4ToNumber(ip: string): number | null {
  const parts = ip.split('.');

  if (parts.length !== 4) {
    return null;
  }

  let value = 0;

  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part) || Number(part) > 255) {
      return null;
    }

    value = value * 256 + Number(part);
  }

  return value;
}

export function isIpv4InSubnet(ip: string, subnet: string): boolean {
  const [network, prefixText] = subnet.split('/');
  const prefix = Number(prefixText);
  const address = ipv4ToNumber(ip);
  const base = ipv4ToNumber(network);

  if (
    address === null ||
    base === null ||
    prefixText === undefined ||
    !Number.isInteger(prefix) ||
    prefix < 0 ||
    prefix > 32
  ) {
    return false;
  }

  const size = 2 ** (32 - prefix);

  return Math.floor(address / size) === Math.floor(base / size);
}

// With no known subnets (an old backend, a router with no such zone) every
// address counts: hiding everything would be worse than showing too much.
export function isLanIpv4(ip: string | null | undefined, subnets: string[]) {
  if (!ip) {
    return false;
  }

  if (subnets.length === 0) {
    return true;
  }

  return subnets.some((subnet) => isIpv4InSubnet(ip, subnet));
}

export function parseLanInfo(stdout: string): LanInfo {
  try {
    const data = JSON.parse(stdout);
    const subnets = Array.isArray(data?.subnets)
      ? data.subnets.filter((item: unknown) => typeof item === 'string')
      : [];
    const staticHosts = Array.isArray(data?.static_hosts)
      ? data.static_hosts
          .filter((item: { ip?: unknown }) => typeof item?.ip === 'string')
          .map(
            (item: {
              section?: string;
              macs?: unknown[];
              ip: string;
              name?: string;
            }) => ({
              section: String(item.section ?? ''),
              macs: (Array.isArray(item.macs) ? item.macs : []).map((mac) =>
                String(mac).toUpperCase(),
              ),
              ip: item.ip,
              name: String(item.name ?? ''),
            }),
          )
      : [];

    return { subnets, staticHosts };
  } catch {
    return EMPTY_LAN_INFO;
  }
}

export function findStaticLease(
  info: LanInfo,
  mac: string,
): StaticLease | undefined {
  const wanted = mac.toUpperCase();

  return info.staticHosts.find((lease) => lease.macs.includes(wanted));
}

// Does the device match what was typed in the search box (name, address, MAC)?
export function deviceMatchesQuery(
  device: { name: string; ip: string; mac: string; addresses?: string[] },
  query: string,
): boolean {
  const needle = query.trim().toLowerCase();

  if (!needle) {
    return true;
  }

  return [device.name, device.ip, device.mac, ...(device.addresses ?? [])].some(
    (field) => field.toLowerCase().includes(needle),
  );
}

export function isValidMac(value: string): boolean {
  return /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(value);
}
