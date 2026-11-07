import { describe, expect, it } from 'vitest';
import { decodeIncyLink, decodeIncyLinks, isIncyLink } from '../incy';

const KEY_HEX =
  'f6d40ea0c8a8899d7c682d09ba0d4165dfe2b3dd45e6bb3e25cb233cf00c2462';

// the cross-platform test vector of the encoder (iv 000102...0b)
const VECTOR =
  'incy://crypt1/AAECAwQFBgcICQoLNyIQL3rDwRZqnyoD8pGKSLXP6o8NdSXQVSSALNbbUyIr__tWGFUexdIfKvvmDnuDGbmBvuppfNef6aKNZUwOm4c-Sg';

// a link built with WebCrypto of the runtime, independent of the code under test
async function seal(text: string): Promise<string> {
  const raw = new Uint8Array(
    KEY_HEX.match(/../g)!.map((byte) => parseInt(byte, 16)),
  );
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, [
    'encrypt',
  ]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const body = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      key,
      new TextEncoder().encode(text),
    ),
  );
  const wire = new Uint8Array(iv.length + body.length);
  wire.set(iv);
  wire.set(body, iv.length);
  return `incy://crypt1/${toBase64Url(wire)}`;
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function fromBase64Url(text: string): Uint8Array {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));

  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

describe('decodeIncyLink', () => {
  it('reads the test vector of the encoder', () => {
    expect(decodeIncyLink(VECTOR)).toEqual({
      url: 'https://sub.example.com/test-vector',
    });
  });

  it('reads a link with a name and a long address, whatever its length', async () => {
    for (const size of [0, 1, 15, 16, 17, 31, 32, 33, 200]) {
      const url = `https://sub.example.com/${'a'.repeat(size)}?x=1&y=ж`;
      const link = await seal(JSON.stringify({ n: 'My VPN', url, v: 1 }));

      expect(decodeIncyLink(link)).toEqual({ url, name: 'My VPN' });
    }
  });

  it('tolerates spaces around the link and a slash at its end', () => {
    expect(decodeIncyLink(`  ${VECTOR}/ \n`)?.url).toBe(
      'https://sub.example.com/test-vector',
    );
  });

  it('rejects a link that was changed', () => {
    const flipped = VECTOR.slice(0, -4) + (VECTOR.endsWith('Sg') ? 'Sh' : 'Sg');

    expect(decodeIncyLink(flipped.replace('AAEC', 'AQEC'))).toBeNull();
    expect(decodeIncyLink(VECTOR.slice(0, -3))).toBeNull();
  });

  // a bit flipped in one place only, so that the payload stays what it was and only the
  // authentication can tell: in the tag (its first, its last byte), in the ciphertext, in the iv
  it('rejects a single flipped bit anywhere, the tag included', () => {
    const wire = fromBase64Url(VECTOR.slice('incy://crypt1/'.length));
    const positions = [
      0,
      11,
      12,
      wire.length - 17,
      wire.length - 16,
      wire.length - 9,
      wire.length - 1,
    ];

    for (const position of positions) {
      const copy = new Uint8Array(wire);

      copy[position] ^= 0x01;
      expect(decodeIncyLink(`incy://crypt1/${toBase64Url(copy)}`)).toBeNull();
    }

    expect(decodeIncyLink(VECTOR)).not.toBeNull();
  });

  it('rejects what is not an incy link', () => {
    expect(decodeIncyLink('https://sub.example.com/x')).toBeNull();
    expect(decodeIncyLink('incy://add/https%3A%2F%2Ffoo.bar')).toBeNull();
    expect(decodeIncyLink('incy://crypt1/')).toBeNull();
    expect(decodeIncyLink('incy://crypt1/!!!')).toBeNull();
  });

  it('rejects a payload that is not the expected JSON', async () => {
    expect(decodeIncyLink(await seal('not json'))).toBeNull();
    expect(decodeIncyLink(await seal('{"v":1}'))).toBeNull();
  });

  // the address goes on to wget and curl: only a single-line http(s) address is let through
  it('rejects an address that is not http(s) or not a single line', async () => {
    for (const url of [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'ftp://host.example/x',
      '--post-file=/etc/shadow',
      'https://a.example/x\nftp://host.example/y',
      'https://a.example/x\r',
      'https://a.example/ x',
      'https://a.example/\u0000',
      'https://',
    ]) {
      expect(decodeIncyLink(await seal(JSON.stringify({ url })))).toBeNull();
    }

    expect(
      decodeIncyLink(await seal(JSON.stringify({ url: 'HTTP://A.example/x' })))
        ?.url,
    ).toBe('http://A.example/x');
  });

  it('does not decrypt a link far longer than any real one', async () => {
    const long = await seal(
      JSON.stringify({ url: `https://a.example/${'a'.repeat(5000)}` }),
    );

    expect(long.length).toBeGreaterThan(4096);
    expect(decodeIncyLink(long)).toBeNull();
  });
});

describe('decodeIncyLinks', () => {
  it('replaces the links and leaves the rest', () => {
    expect(
      decodeIncyLinks(['https://a.example/x', VECTOR, 'incy://crypt1/AAAA']),
    ).toEqual({
      values: [
        'https://a.example/x',
        'https://sub.example.com/test-vector',
        'incy://crypt1/AAAA',
      ],
      decoded: 1,
      undecoded: 1,
    });
  });

  it('knows an incy link by its scheme', () => {
    expect(isIncyLink(' INCY://crypt1/x')).toBe(true);
    expect(isIncyLink('https://a.example')).toBe(false);
  });
});
