import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';

// TODO refactor current validation and add tests
export function validateProxyUrl(url: string): ValidationResult {
  if (url.startsWith('ss://')) {
    return validateShadowsocksUrl(url);
  }

  if (url.startsWith('vless://')) {
    return validateVlessUrl(url);
  }

  if (url.startsWith('trojan://')) {
    return validateTrojanUrl(url);
  }

  if (/^socks(4|4a|5):\/\//.test(url)) {
    return validateSocksUrl(url);
  }

  return {
    valid: false,
    message: _(
      'URL must start with vless://, ss://, trojan://, or socks4/5://',
    ),
  };
}
