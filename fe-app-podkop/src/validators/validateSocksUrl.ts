import { ValidationResult } from './types';
import { validateDomain } from './validateDomain';
import { validateIPV4 } from './validateIp';

export function validateSocksUrl(url: string): ValidationResult {
  try {
    if (!/^socks(4|4a|5):\/\//.test(url)) {
      return {
        valid: false,
        message: _(
          'Invalid SOCKS URL: must start with socks4://, socks4a://, or socks5://',
        ),
      };
    }

    if (!url || /\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: must not contain spaces'),
      };
    }

    const body = url.replace(/^socks(4|4a|5):\/\//, '');
    const [authAndHost] = body.split('#'); // отбрасываем hash, если есть
    const [credentials, hostPortPart] = authAndHost.includes('@')
      ? authAndHost.split('@')
      : [null, authAndHost];

    if (credentials) {
      const [username, _password] = credentials.split(':');
      if (!username) {
        return {
          valid: false,
          message: _('Invalid SOCKS URL: missing username'),
        };
      }
    }

    if (!hostPortPart) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: missing host and port'),
      };
    }

    const [host, port] = hostPortPart.split(':');

    if (!host) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: missing hostname or IP'),
      };
    }

    if (!port) {
      return { valid: false, message: _('Invalid SOCKS URL: missing port') };
    }

    const portNum = Number(port);
    if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: invalid port number'),
      };
    }

    const ipv4Result = validateIPV4(host);
    const domainResult = validateDomain(host);

    if (!ipv4Result.valid && !domainResult.valid) {
      return {
        valid: false,
        message: _('Invalid SOCKS URL: invalid host format'),
      };
    }
  } catch (_e) {
    return { valid: false, message: _('Invalid SOCKS URL: parsing failed') };
  }

  return { valid: true, message: _('Valid') };
}
