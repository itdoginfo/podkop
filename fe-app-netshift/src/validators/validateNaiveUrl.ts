import { ValidationResult } from './types';
import { validateDomain } from './validateDomain';
import { validateIPV4 } from './validateIp';

// NaiveProxy link: naive+https://user:pass@host[:port], naive+quic://..., or a
// plain https://user:pass@host[:port] (an https link with a login is how a
// NaiveProxy server is written down).
export function isNaiveUrl(url: string): boolean {
  return (
    /^naive(\+https|\+quic)?:\/\//.test(url) ||
    /^https:\/\/[^/@]*:[^/@]*@/.test(url)
  );
}

export function validateNaiveUrl(url: string): ValidationResult {
  // The message is translated where it is written (as a literal): the string extractor
  // only sees _('...') with a literal argument.
  const invalid = (message: string): ValidationResult => ({
    valid: false,
    message,
  });

  if (/\s/.test(url)) {
    return invalid(_('Invalid NaiveProxy URL: must not contain spaces'));
  }

  const body = url.replace(/^(naive(\+https|\+quic)?|https):\/\//, '');
  const [authority] = body.split(/[/?#]/);
  const at = authority.lastIndexOf('@');

  if (at < 0) {
    return invalid(
      _('Invalid NaiveProxy URL: login and password are required'),
    );
  }

  const credentials = authority.slice(0, at);
  const hostPort = authority.slice(at + 1);
  const colon = credentials.indexOf(':');

  if (colon <= 0 || colon === credentials.length - 1) {
    return invalid(
      _('Invalid NaiveProxy URL: login and password are required'),
    );
  }

  const match = hostPort.match(/^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/);

  if (!match) {
    return invalid(_('Invalid NaiveProxy URL: missing host'));
  }

  const host = match[1];
  const port = match[2];

  if (port !== undefined) {
    const number = Number(port);

    if (number < 1 || number > 65535) {
      return invalid(_('Invalid NaiveProxy URL: invalid port'));
    }
  }

  if (
    !host.startsWith('[') &&
    !validateIPV4(host).valid &&
    !validateDomain(host).valid
  ) {
    return invalid(_('Invalid NaiveProxy URL: invalid host'));
  }

  return { valid: true, message: _('Valid') };
}
