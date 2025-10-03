import { ValidationResult } from './types';

// TODO refactor current validation and add tests
export function validateTrojanUrl(url: string): ValidationResult {
  if (!url.startsWith('trojan://')) {
    return {
      valid: false,
      message: 'Invalid Trojan URL: must start with trojan://',
    };
  }

  try {
    const parsedUrl = new URL(url);

    if (!parsedUrl.username || !parsedUrl.hostname || !parsedUrl.port) {
      return {
        valid: false,
        message: 'Invalid Trojan URL: must contain username, hostname and port',
      };
    }
  } catch (e) {
    return { valid: false, message: 'Invalid Trojan URL: parsing failed' };
  }

  return { valid: true, message: 'Valid' };
}
