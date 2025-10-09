import { describe, it, expect } from 'vitest';
import { validateShadowsocksUrl } from '../validateShadowsocksUrl';

const validUrls = [
  [
    'no-client',
    'ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206ZG1DbHkvWmgxNVd3OStzK0dGWGlGVElrcHc3Yy9xQ0lTYUJyYWk3V2hoWT0@127.0.0.1:25144?type=tcp#shadowsocks-no-client',
  ],
  [
    'client',
    'ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206S3FiWXZiNkhwb1RmTUt0N2VGcUZQSmJNNXBXaHlFU0ZKTXY2dEp1Ym1Fdz06dzRNMEx5RU9OTGQ5SWlkSGc0endTbzN2R3h4NS9aQ3hId0FpaWlxck5hcz0@127.0.0.1:26627?type=tcp#shadowsocks-client',
  ],
  [
    'plain-user',
    'ss://2022-blake3-aes-256-gcm:dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=@127.0.0.1:27214?type=tcp#shadowsocks-plain-user',
  ],
];

const invalidUrls = [
  ['No prefix', 'uuid@127.0.0.1:443?type=tcp'],
  ['No host', 'ss://password@:443?type=tcp'],
  ['No port', 'ss://password@127.0.0.1?type=tcp'],
  ['Invalid port', 'ss://password@127.0.0.1:abc?type=tcp'],
  ['Missing type', 'ss://password@127.0.0.1:443'],
  ['Contains space', 'ss://password@127.0.0.1:443?type=tcp #extra'],
];

describe('validateShadowsocksUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateShadowsocksUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateShadowsocksUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('detects invalid port range', () => {
    const res = validateShadowsocksUrl(
      'ss://password@127.0.0.1:99999?type=tcp',
    );
    expect(res.valid).toBe(false);
  });
});
