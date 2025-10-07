import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';

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

  return {
    valid: false,
    message: _('URL must start with vless:// or ss:// or trojan://'),
  };
}
