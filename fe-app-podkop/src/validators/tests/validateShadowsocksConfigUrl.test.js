import { describe, it, expect } from 'vitest';
import { validateShadowsocksConfigUrl } from '../validateShadowsocksConfigUrl';

const validUrls = [
  [
    'sample',
    'ssconf://127.0.0.1/abcdef',
  ],
];

const invalidUrls = [
  ['No prefix', '127.0.0.1/abcdef'],
  ['Contains space', 'ssconf://127.0.0.1/abc def'],
];

describe('validateShadowsocksConfigUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateShadowsocksConfigUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateShadowsocksConfigUrl(url);
      expect(res.valid).toBe(false);
    });
  });
});
