import { ValidationResult } from './types';
import { validateIPV4, validateIPV6 } from './validateIp';

const ZONE_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/i;

// "<zone> <server>" (or the dnsmasq form "/<zone>/<server>"): the zone is a
// domain or a single label (a TLD such as "ru"), the server an IP address with
// an optional "#port". Mirrors dns_forward_normalize in dnsforward.sh.
export function splitDnsForward(
  entry: string,
): { zone: string; server: string } | null {
  const value = entry.trim();

  if (value.startsWith('/')) {
    const match = value.match(/^\/([^/]*)\/(.*)$/);

    return match ? { zone: match[1], server: match[2].trim() } : null;
  }

  const match = value.match(/^(\S+)\s+(\S.*)$/);

  return match ? { zone: match[1], server: match[2].trim() } : null;
}

export function validateDnsForward(entry: string): ValidationResult {
  const parts = splitDnsForward(entry);

  if (!parts) {
    return {
      valid: false,
      message: _('Use "zone server", for example: ru 77.88.8.8'),
    };
  }

  const zone = parts.zone.replace(/^\./, '');

  if (
    !zone ||
    zone.length > 253 ||
    !zone.split('.').every((label) => ZONE_LABEL.test(label))
  ) {
    return { valid: false, message: _('Invalid zone') };
  }

  const [address, port, ...rest] = parts.server.split('#');

  if (rest.length) {
    return { valid: false, message: _('Invalid DNS server') };
  }

  if (port !== undefined) {
    const number = Number(port);

    if (!/^\d+$/.test(port) || number < 1 || number > 65535) {
      return {
        valid: false,
        message: _('Invalid port number. Must be 1-65535'),
      };
    }
  }

  const isIPv6 = address.includes(':');
  const addressValid = isIPv6
    ? validateIPV6(address).valid && !address.startsWith('[')
    : validateIPV4(address).valid;

  if (!addressValid) {
    return {
      valid: false,
      message: _('The server must be an IP address, optionally with #port'),
    };
  }

  return { valid: true, message: _('Valid') };
}
