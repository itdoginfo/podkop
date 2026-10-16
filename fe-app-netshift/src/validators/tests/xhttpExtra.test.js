import { describe, expect, it } from 'vitest';
import { validateVlessUrl } from '../validateVlessUrl';

// XHTTP links of 3x-ui and autoXRAY carry the transport options in `extra` (percent-encoded
// JSON) and, in 3x-ui, x_padding_bytes next to it: the form must accept them.
describe('validateVlessUrl: XHTTP extra', () => {
  const extra =
    '%7B%22noGRPCHeader%22%3Afalse%2C%22xPaddingBytes%22%3A%22150-400%22%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%222-4%22%7D%7D';
  const id = '29a8999e-3cff-4de5-8ae5-27645a3a6615';

  it('accepts the autoXRAY link', () => {
    const url = `vless://${id}@host.example:443?security=tls&alpn=h2&type=xhttp&mode=stream-up&path=%2Fp&extra=${extra}&sni=host.example&fp=firefox#x`;

    expect(validateVlessUrl(url).valid).toBe(true);
  });

  it('accepts the 3x-ui link (extra and x_padding_bytes, security none)', () => {
    const url = `vless://${id}@host.example:4443?encryption=none&extra=${extra}&host=&mode=auto&path=%2F&security=none&type=xhttp&x_padding_bytes=100-1000#x`;

    expect(validateVlessUrl(url).valid).toBe(true);
  });
});
