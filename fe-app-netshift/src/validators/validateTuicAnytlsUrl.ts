import { ValidationResult } from './types';
import { validateDomain } from './validateDomain';
import { validateIPV4 } from './validateIp';

// tuic://uuid:password@host[:port]?... and anytls://password@host[:port]?...
function validateCredentialUrl(
  url: string,
  scheme: 'tuic' | 'anytls',
  title: string,
): ValidationResult {
  const invalid = (message: string): ValidationResult => ({
    valid: false,
    message: _(message),
  });

  if (/\s/.test(url)) {
    return invalid(`Invalid ${title} URL: must not contain spaces`);
  }

  const body = url.slice(`${scheme}://`.length);
  const [authority] = body.split(/[/?#]/);
  const at = authority.lastIndexOf('@');

  if (at <= 0) {
    return invalid(
      scheme === 'tuic'
        ? `Invalid ${title} URL: uuid and password are required`
        : `Invalid ${title} URL: password is required`,
    );
  }

  const hostPort = authority.slice(at + 1);
  const match = hostPort.match(/^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/);

  if (!match) {
    return invalid(`Invalid ${title} URL: missing host`);
  }

  const host = match[1];
  const port = match[2];

  if (port !== undefined && (Number(port) < 1 || Number(port) > 65535)) {
    return invalid(`Invalid ${title} URL: invalid port`);
  }

  if (
    !host.startsWith('[') &&
    !validateIPV4(host).valid &&
    !validateDomain(host).valid
  ) {
    return invalid(`Invalid ${title} URL: invalid host`);
  }

  return { valid: true, message: _('Valid') };
}

export function validateTuicUrl(url: string): ValidationResult {
  return validateCredentialUrl(url, 'tuic', 'TUIC');
}

export function validateAnytlsUrl(url: string): ValidationResult {
  return validateCredentialUrl(url, 'anytls', 'AnyTLS');
}
