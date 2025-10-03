import { ValidationResult } from './types';

export function validateUrl(
  url: string,
  protocols: string[] = ['http:', 'https:'],
): ValidationResult {
  try {
    const parsedUrl = new URL(url);

    if (!protocols.includes(parsedUrl.protocol)) {
      return {
        valid: false,
        message: `URL must use one of the following protocols: ${protocols.join(', ')}`,
      };
    }
    return { valid: true, message: 'Valid' };
  } catch (_e) {
    return { valid: false, message: 'Invalid URL format' };
  }
}
