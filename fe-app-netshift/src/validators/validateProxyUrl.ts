import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';
import { validateHysteria2Url } from './validateHysteriaUrl';
import { validateVmessUrl } from './validateVmessUrl';
import { isNaiveUrl, validateNaiveUrl } from './validateNaiveUrl';
import { validateAnytlsUrl, validateTuicUrl } from './validateTuicAnytlsUrl';
import { getCoreCapabilities } from '../helpers/coreCapabilities';

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

  if (trimmedUrl.startsWith('vmess://')) {
    if (!getCoreCapabilities().vmess) {
      return {
        valid: false,
        message: _('VMess needs the sing-box-extended core'),
      };
    }

    return validateVmessUrl(trimmedUrl);
  }

  if (/^socks(4|4a|5):\/\//.test(trimmedUrl)) {
    return validateSocksUrl(trimmedUrl);
  }

  if (
    trimmedUrl.startsWith('hysteria2://') ||
    trimmedUrl.startsWith('hy2://')
  ) {
    if (!getCoreCapabilities().quic) {
      return {
        valid: false,
        message: _('Hysteria2 needs a sing-box core built with QUIC'),
      };
    }

    return validateHysteria2Url(trimmedUrl);
  }

  if (trimmedUrl.startsWith('tuic://')) {
    if (!getCoreCapabilities().quic) {
      return {
        valid: false,
        message: _('TUIC needs a sing-box core built with QUIC'),
      };
    }

    return validateTuicUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('anytls://')) {
    return validateAnytlsUrl(trimmedUrl);
  }

  if (isNaiveUrl(trimmedUrl)) {
    return validateNaiveUrl(trimmedUrl);
  }

  return {
    valid: false,
    message: _(
      'URL must start with vless://, vmess://, ss://, trojan://, socks4/5://, hysteria2://hy2://, tuic://, anytls:// or naive+https://',
    ),
  };
}
