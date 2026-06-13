import { describe, it, expect } from 'vitest';
import { validateTrojanUrl } from '../validateTrojanUrl';

const validUrls = [
  // TCP
  [
    'tcp + none',
    'trojan://04agAQapcl@127.0.0.1:33641?type=tcp&security=none#trojan-tcp-none',
  ],
  [
    'tcp + reality',
    'trojan://cME3ZlUrYF@127.0.0.1:43772?type=tcp&security=reality&pbk=DckTwU6p6pTX9QxFXOi6vH4Vzt_RCE1vMCnj2c6hvjw&fp=chrome&sni=google.com&sid=221a80cf94&spx=%2F#trojan-tcp-reality',
  ],
  [
    'tcp + tls',
    'trojan://EJjpAj02lg@127.0.0.1:11381?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-tcp-tls',
  ],
  [
    'tcp + tls + insecure',
    'trojan://ZP2Ik5sxN3@127.0.0.1:16247?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-tcp-tls-insecure',
  ],
  [
    'tcp + tls + ech',
    'trojan://90caP481ay@127.0.0.1:59708?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACC2y%2BAe4dqthLNpfvmtE6g%2BnaJ%2FciK6P%2BREbRLkR%2Fg%2FEgAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-tcp-tls-ech',
  ],

  // mKCP
  [
    'mKCP + none',
    'trojan://N5v7iIOe9G@127.0.0.1:36319?type=kcp&headerType=none&seed=P91wFIfjzZ&security=none#trojan-mKCP',
  ],

  // WebSocket
  [
    'ws + none',
    'trojan://G3cE9phv1g@127.0.0.1:57370?type=ws&path=%2Fwspath&host=google.com&security=none#trojan-websocket-none',
  ],
  [
    'ws + tls',
    'trojan://FBok41WczO@127.0.0.1:59919?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-websocket-tls',
  ],
  [
    'ws + tls + insecure',
    'trojan://bhwvndUBPA@127.0.0.1:22969?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-websocket-tls-insecure',
  ],
  [
    'ws + tls + ech',
    'trojan://pwiduqFUWO@127.0.0.1:46765?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACCFcQYEtwrFOidJJLYHvSiN%2BljRgaAIrNHoVnio3uXAOwAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-websocket-tls-ech',
  ],

  // gRPC
  [
    'grpc + none',
    'trojan://WMR7qkKhsV@127.0.0.1:27897?type=grpc&serviceName=TunService&authority=authority&security=none#trojan-gRPC-none',
  ],
  [
    'grpc + reality',
    'trojan://KVuRNsu6KG@127.0.0.1:46077?type=grpc&serviceName=TunService&authority=authority&security=reality&pbk=Xn59i4gum3ppCICS6-_NuywrhHIVVAH54b2mjd5CFkE&fp=chrome&sni=google.com&sid=e5be&spx=%2F#trojan-gRPC-reality',
  ],
  [
    'grpc + tls',
    'trojan://7BJtbywy8h@127.0.0.1:10627?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-gRPC-tls',
  ],
  [
    'grpc + tls + insecure',
    'trojan://TI3PakvtP4@127.0.0.1:10435?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-gRPC-tls-insecure',
  ],
  [
    'grpc + tls + ech',
    'trojan://mbzoVKL27h@127.0.0.1:38681?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACCq72Ru3VbFlDpKttl3LccmInu8R2oAsCr8wzyxB0vZZQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-gRPC-tls-ech',
  ],

  // HTTPUpgrade
  [
    'httpupgrade + none',
    'trojan://uc44gBwOKQ@127.0.0.1:29085?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=none#trojan-httpupgrade-none',
  ],
  [
    'httpupgrade + tls',
    'trojan://MhNxbcVB14@127.0.0.1:32700?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-httpupgrade-tls',
  ],
  [
    'httpupgrade + tls + insecure',
    'trojan://7SOQFUpLob@127.0.0.1:28474?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-httpupgrade-tls-insecure',
  ],
  [
    'httpupgrade + tls + ech',
    'trojan://ou8pLSyx9N@127.0.0.1:17737?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACB%2FlkIkit%2BblFzE7PtbYDVF3NXK8olXJ5a7YwY%2Biy9QQwAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-httpupgrade-tls-ech',
  ],

  // XHTTP
  [
    'xhttp + none',
    'trojan://VEetltxLtw@127.0.0.1:59072?type=xhttp&path=%2Fxhttppath&host=google.com&mode=auto&security=none#trojan-xhttp',
  ],
];

const invalidUrls = [
  ['No prefix', 'uuid@host:443?type=tcp&security=tls'],
  ['No password', 'trojan://@127.0.0.1:443?type=tcp&security=tls'],
  ['No host', 'trojan://pass@:443?type=tcp&security=tls'],
  ['No port', 'trojan://pass@127.0.0.1?type=tcp&security=tls'],
  ['Invalid port', 'trojan://pass@127.0.0.1:abc?type=tcp&security=tls'],
  [
    'tcp + reality + unexpected spaces',
    'trojan://cME3ZlUrYF@127.0.0.1:43772?type=tcp&security=reality&pbk=DckTwU6p6pTX9QxFXOi6vH4Vzt_RCE1vMCnj2c6hvjw&fp=chrome&sni= google.com&sid=221a80cf94&spx=%2F#trojan-tcp-reality',
  ],
];

describe('validateTrojanUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateTrojanUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateTrojanUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('detects invalid port range', () => {
    const res = validateTrojanUrl(
      'trojan://pass@127.0.0.1:99999?type=tcp&security=tls',
    );
    expect(res.valid).toBe(false);
  });
});
