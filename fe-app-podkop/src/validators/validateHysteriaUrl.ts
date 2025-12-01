import { ValidationResult } from './types';
import { parseQueryString } from '../helpers/parseQueryString';

export function validateHysteria2Url(url: string): ValidationResult {
  try {
    const isHY2 = url.startsWith('hysteria2://');
    const isHY2Short = url.startsWith('hy2://');

    if (!isHY2 && !isHY2Short) {
      return {
        valid: false,
        message: _('Invalid HY2 URL: must start with hysteria2:// or hy2://'),
      };
    }

    if (/\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid HY2 URL: must not contain spaces'),
      };
    }

    const prefix = isHY2 ? 'hysteria2://' : 'hy2://';
    const body = url.slice(prefix.length);

    const [mainPart] = body.split('#');
    const [authHostPort, queryString] = mainPart.split('?');

    if (!authHostPort)
      return {
        valid: false,
        message: _('Invalid HY2 URL: missing credentials/server'),
      };

    const [passwordPart, hostPortPart] = authHostPort.split('@');

    if (!passwordPart)
      return { valid: false, message: _('Invalid HY2 URL: missing password') };

    if (!hostPortPart)
      return {
        valid: false,
        message: _('Invalid HY2 URL: missing host & port'),
      };

    const [host, port] = hostPortPart.split(':');

    if (!host) {
      return { valid: false, message: _('Invalid HY2 URL: missing host') };
    }

    if (!port) {
      return { valid: false, message: _('Invalid HY2 URL: missing port') };
    }

    const cleanedPort = port.replace('/', '');
    const portNum = Number(cleanedPort);

    if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
      return {
        valid: false,
        message: _('Invalid HY2 URL: invalid port number'),
      };
    }

    if (queryString) {
      const params = parseQueryString(queryString);
      const paramsKeys = Object.keys(params);

      if (
        paramsKeys.includes('insecure') &&
        !['0', '1'].includes(params.insecure)
      ) {
        return {
          valid: false,
          message: _('Invalid HY2 URL: insecure must be 0 or 1'),
        };
      }

      const validObfsTypes = ['none', 'salamander'];

      if (
        paramsKeys.includes('obfs') &&
        !validObfsTypes.includes(params.obfs)
      ) {
        return {
          valid: false,
          message: _('Invalid HY2 URL: unsupported obfs type'),
        };
      }

      if (
        paramsKeys.includes('obfs') &&
        params.obfs !== 'none' &&
        !params['obfs-password']
      ) {
        return {
          valid: false,
          message: _(
            'Invalid HY2 URL: obfs-password required when obfs is set',
          ),
        };
      }

      if (paramsKeys.includes('sni') && !params.sni) {
        return {
          valid: false,
          message: _('Invalid HY2 URL: sni cannot be empty'),
        };
      }
    }

    return { valid: true, message: _('Valid') };
  } catch (_e) {
    return { valid: false, message: _('Invalid HY2 URL: parsing failed') };
  }
}
