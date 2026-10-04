import { validateDNS } from './validateDns';
import { ValidationResult } from './types';

const DNS_POOL_SCHEMES = ['udp', 'tcp', 'dot', 'doh', 'doh3', 'doq'];
const DNS_POOL_PATH_SCHEMES = ['doh', 'doh3'];

// One entry of the additional DNS servers list: <scheme>://<host>[:port][/path]
export function validateDnsPoolServer(value: string): ValidationResult {
  if (!value) {
    return { valid: false, message: _('DNS server cannot be empty') };
  }

  const separator = value.indexOf('://');

  if (separator < 0) {
    return {
      valid: false,
      message: _(
        'Use scheme://host[:port][/path], where scheme is udp, tcp, dot, doh, doh3 or doq. Example: doh://dns.google/dns-query',
      ),
    };
  }

  const scheme = value.slice(0, separator);
  const rest = value.slice(separator + 3);

  if (!DNS_POOL_SCHEMES.includes(scheme)) {
    return {
      valid: false,
      message: _('Unknown DNS scheme. Use udp, tcp, dot, doh, doh3 or doq'),
    };
  }

  if (!DNS_POOL_PATH_SCHEMES.includes(scheme) && rest.includes('/')) {
    return {
      valid: false,
      message: _('A path is only allowed for doh and doh3'),
    };
  }

  if (/\s/.test(value)) {
    return { valid: false, message: _('DNS server must not contain spaces') };
  }

  const address = validateDNS(rest);

  if (!address.valid) {
    return address;
  }

  return { valid: true, message: _('Valid') };
}

// Per-query timeout of the DNS pool: a number and a unit, e.g. 500ms or 2s
export function validateDnsPoolTimeout(value: string): ValidationResult {
  if (/^[1-9][0-9]*(ms|s)$/.test(value)) {
    return { valid: true, message: _('Valid') };
  }

  return {
    valid: false,
    message: _('Invalid timeout. Examples: 500ms, 2s'),
  };
}
