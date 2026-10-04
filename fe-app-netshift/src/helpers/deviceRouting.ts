// Per-device routing for the "Local devices" page. A device (a LAN source IP) is
// in one of three states: default (routed by the lists as usual), excluded
// (sent directly, settings.routing_excluded_ips) or fully routed through one
// section (that section's fully_routed_ips). The state lives in those UCI lists;
// these helpers only compute it and the lists a change leads to.

export const DEVICE_ROUTE_DEFAULT = '';
// Not a possible UCI section name (those never contain ':'), so it can not be
// mistaken for the name of a section the device is routed through.
export const DEVICE_ROUTE_EXCLUDED = 'netshift:excluded';

export interface DeviceRoutingState {
  // section name -> its fully_routed_ips
  sections: Record<string, string[]>;
  // settings.routing_excluded_ips
  excluded: string[];
}

export function toIpList(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map((item) => String(item).trim()).filter(Boolean);
  }

  if (typeof value === 'string') {
    return value
      .split(/[\s,]+/)
      .map((item) => item.trim())
      .filter(Boolean);
  }

  return [];
}

// DEVICE_ROUTE_DEFAULT, DEVICE_ROUTE_EXCLUDED or the name of the section the
// device is fully routed through (the first one if the config lists it twice).
export function getDeviceRoute(state: DeviceRoutingState, ip: string): string {
  for (const [section, ips] of Object.entries(state.sections)) {
    if (ips.includes(ip)) {
      return section;
    }
  }

  if (state.excluded.includes(ip)) {
    return DEVICE_ROUTE_EXCLUDED;
  }

  return DEVICE_ROUTE_DEFAULT;
}

// The state after moving the device to `route`: it is removed from every list and
// added to the one the route names, so it is never in two places at once.
export function setDeviceRoute(
  state: DeviceRoutingState,
  ip: string,
  route: string,
): DeviceRoutingState {
  const sections: Record<string, string[]> = {};

  for (const [section, ips] of Object.entries(state.sections)) {
    sections[section] = ips.filter((item) => item !== ip);
  }

  const excluded = state.excluded.filter((item) => item !== ip);

  if (route === DEVICE_ROUTE_EXCLUDED) {
    excluded.push(ip);
  } else if (route !== DEVICE_ROUTE_DEFAULT) {
    sections[route] = [...(sections[route] ?? []), ip];
  }

  return { sections, excluded };
}

// Source IPs that appear in the lists, in first-seen order and without
// duplicates (sections first, then the excluded ones).
export function listedDeviceIps(state: DeviceRoutingState): string[] {
  const seen = new Set<string>();

  for (const ips of [...Object.values(state.sections), state.excluded]) {
    ips.forEach((ip) => seen.add(ip));
  }

  return [...seen];
}
