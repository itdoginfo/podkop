import { ValidationResult } from './types';

export function validateUrl(
  url: string,
  protocols = ['http:', 'https:'],
): ValidationResult {
  if (!url.length) {
    return { valid: false, message: _('Invalid URL format') };
  }

  const hasValidProtocol = protocols.some((p) => url.indexOf(p + '//') === 0);

  if (!hasValidProtocol)
    return {
      valid: false,
      message:
        _('URL must use one of the following protocols:') +
        ' ' +
        protocols.join(', '),
    };

  const regex = new RegExp(
    `^(?:${protocols.map((p) => p.replace(':', '')).join('|')})://` +
      `(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?::\\d+)?(?:/[^\\s]*)?$`,
  );

  if (regex.test(url)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid URL format') };
}
