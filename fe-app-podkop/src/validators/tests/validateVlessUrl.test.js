import { describe, it, expect } from 'vitest';
import { validateVlessUrl } from '../validateVlessUrl';

const validUrls = [
  // TCP
  [
    'tcp + none',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?type=tcp&encryption=none&security=none#vless-tcp-none',
  ],
  [
    'tcp + reality',
    'vless://e95163dc-905e-480a-afe5-20b146288679@127.0.0.1:16399?type=tcp&encryption=none&security=reality&pbk=tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM&fp=chrome&sni=google.com&sid=f6&spx=%2F#vless-tcp-reality',
  ],
  [
    'tcp + tls',
    'vless://2e9e8288-060e-4da2-8b9f-a1c81826feb7@127.0.0.1:19316?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-tcp-tls',
  ],
  // mKCP
  [
    'mKCP + none',
    'vless://72e201d7-7841-4a32-b266-4aa3eb776d51@127.0.0.1:17270?type=kcp&encryption=none&headerType=none&seed=AirziWi4ng&security=none#vless-mKCP',
  ],
  // WebSocket
  [
    'ws + none',
    'vless://d86daef7-565b-4ecd-a9ee-bac847ad38e6@127.0.0.1:12928?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=none#vless-websocket-none',
  ],
  [
    'ws + tls',
    'vless://fe0f0941-09a9-4e46-bc69-e00190d7bb9c@127.0.0.1:10156?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=tls&fp=chrome&sni=google.com#vless-websocket-tls',
  ],
  // gRPC
  [
    'grpc + none',
    'vless://974b39e3-f7bf-42b9-933c-16699c635e77@127.0.0.1:15633?type=grpc&encryption=none&serviceName=TunService&security=none#vless-gRPC-none',
  ],
  [
    'grpc + reality',
    'vless://651e7eca-5152-46f1-baf2-d502e0af7b27@127.0.0.1:28535?type=grpc&encryption=none&serviceName=TunService&security=reality&pbk=nhZ7NiKfcqESa5ZeBFfsq9o18W-OWOAHLln9UmuVXSk&fp=chrome&sni=google.com&sid=11cbaeaa&spx=%2F#vless-gRPC-reality',
  ],
  // HTTPUpgrade
  [
    'httpupgrade + none',
    'vless://2b98f144-847f-42f7-8798-e1a32d27bdc7@127.0.0.1:47154?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=none#vless-httpupgrade-none',
  ],
  [
    'httpupgrade + tls',
    'vless://76dbd0ff-1a35-4f0c-a9ba-3c5890b7dea6@127.0.0.1:50639?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=tls&sni=google.com#vless-httpupgrade-tls',
  ],
  // XHTTP
  [
    'xhttp + none',
    'vless://c2841505-ec32-4b8d-b6dd-3e19d648c321@127.0.0.1:45507?type=xhttp&encryption=none&path=%2Fxhttppath&host=xhttp&mode=auto&security=none#vless-xhttp',
  ],
];

const invalidUrls = [
  ['No prefix', 'uuid@host:443?type=tcp&security=tls'],
  ['No uuid', 'vless://@127.0.0.1:443?type=tcp&security=tls'],
  ['No host', 'vless://uuid@:443?type=tcp&security=tls'],
  ['No port', 'vless://uuid@127.0.0.1?type=tcp&security=tls'],
  ['Invalid port', 'vless://uuid@127.0.0.1:abc?type=tcp&security=tls'],
  ['Missing type', 'vless://uuid@127.0.0.1:443?security=tls'],
  ['Missing security', 'vless://uuid@127.0.0.1:443?type=tcp'],
  [
    'reality without pbk',
    'vless://uuid@127.0.0.1:443?type=tcp&security=reality&fp=chrome',
  ],
  [
    'reality without fp',
    'vless://uuid@127.0.0.1:443?type=tcp&security=reality&pbk=abc',
  ],
  [
    'tcp + reality + unexpected spaces',
    'vless://e95163dc-905e-480a-afe5-20b146288679@127.0.0.1:16399?type=tcp&encryption=none&security=reality&pbk=tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM&fp=chrome&sni= google.com&sid=f6&spx=%2F#vless-tcp-reality',
  ],
];

describe('validateVlessUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateVlessUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateVlessUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('detects invalid port range', () => {
    const res = validateVlessUrl(
      'vless://uuid@127.0.0.1:99999?type=tcp&security=tls',
    );
    expect(res.valid).toBe(false);
  });
});
