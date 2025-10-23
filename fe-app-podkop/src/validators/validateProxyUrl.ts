import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';

// TODO refactor current validation and add tests
export function validateProxyUrl(url: string): ValidationResult {
  const trimmedUrl = url.trim();

  if (trimmedUrl.startsWith('ss://')) {
    return validateShadowsocksUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('vless://')) {
    return validateVlessUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('trojan://')) {
    return validateTrojanUrl(trimmedUrl);
  }

  if (/^socks(4|4a|5):\/\//.test(trimmedUrl)) {
    return validateSocksUrl(trimmedUrl);
  }

  return {
    valid: false,
    message: _(
      'URL must start with vless://, ss://, trojan://, or socks4/5://',
    ),
  };
}
