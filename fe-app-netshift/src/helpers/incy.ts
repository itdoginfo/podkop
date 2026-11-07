// Subscription links of the INCY clients: incy://crypt1/<payload>, the address of a
// subscription wrapped so that chat bots and scanners do not see it
// (https://github.com/INCY-DEV/incy-link-encoder, MIT).
//
// The wrapping is obfuscation, not secrecy: the AES-256-GCM key is the same in every INCY app and
// in the published encoder, which says so itself. The key below is that one, derived the way
// the encoder does (SHA-256 of the salt parts and 32 bytes of each of its two key assets); its
// own SHA-256 is b6bf7084...c08c, the fingerprint the encoder checks.
//
// Written out here, with no dependency: WebCrypto only exists on https pages and the router's
// LuCI is often served over http. The wire format is iv (12 bytes) || ciphertext || tag (16), and
// the text is JSON {"url": ..., "v": 1, "n": <name>}.

const LINK_PREFIX = 'incy://crypt1/';
// a link is about a hundred characters; anything far longer is not one, and is not worth the time to decrypt
const MAX_LINK_LEN = 4096;
const KEY_HEX =
  'f6d40ea0c8a8899d7c682d09ba0d4165dfe2b3dd45e6bb3e25cb233cf00c2462';
const IV_LEN = 12;
const TAG_LEN = 16;

export interface IncyLink {
  url: string;
  name?: string;
}

export function isIncyLink(value: string): boolean {
  return value.trim().toLowerCase().startsWith('incy://');
}

// --- AES-256, the encryption direction only (GCM needs nothing else)

const SBOX = new Uint8Array(256);

(function buildSbox() {
  const exp = new Uint8Array(256);
  const log = new Uint8Array(256);
  let x = 1;

  for (let i = 0; i < 255; i++) {
    exp[i] = x;
    log[x] = i;
    x ^= (x << 1) ^ (x & 0x80 ? 0x11b : 0);
    x &= 0xff;
  }

  for (let i = 0; i < 256; i++) {
    const inv = i === 0 ? 0 : exp[(255 - log[i]) % 255];
    let s = inv;

    for (let r = 1; r <= 4; r++) {
      s ^= ((inv << r) | (inv >> (8 - r))) & 0xff;
    }

    SBOX[i] = s ^ 0x63;
  }
})();

function xtime(a: number): number {
  return ((a << 1) ^ (a & 0x80 ? 0x1b : 0)) & 0xff;
}

function expandKey(key: Uint8Array): Uint8Array {
  const nk = 8;
  const rounds = 14;
  const w = new Uint8Array(16 * (rounds + 1));
  w.set(key);
  let rcon = 1;

  for (let i = nk; i < 4 * (rounds + 1); i++) {
    const t = w.slice(4 * (i - 1), 4 * i);

    if (i % nk === 0) {
      const first = t[0];
      t[0] = SBOX[t[1]] ^ rcon;
      t[1] = SBOX[t[2]];
      t[2] = SBOX[t[3]];
      t[3] = SBOX[first];
      rcon = xtime(rcon);
    } else if (i % nk === 4) {
      for (let j = 0; j < 4; j++) {
        t[j] = SBOX[t[j]];
      }
    }

    for (let j = 0; j < 4; j++) {
      w[4 * i + j] = w[4 * (i - nk) + j] ^ t[j];
    }
  }

  return w;
}

function encryptBlock(roundKeys: Uint8Array, input: Uint8Array): Uint8Array {
  const s = new Uint8Array(input);

  const addRoundKey = (round: number) => {
    for (let i = 0; i < 16; i++) {
      s[i] ^= roundKeys[16 * round + i];
    }
  };

  addRoundKey(0);

  for (let round = 1; round <= 14; round++) {
    for (let i = 0; i < 16; i++) {
      s[i] = SBOX[s[i]];
    }

    // ShiftRows (state is column-major)
    let t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    t = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t;

    if (round < 14) {
      for (let c = 0; c < 16; c += 4) {
        const a0 = s[c];
        const a1 = s[c + 1];
        const a2 = s[c + 2];
        const a3 = s[c + 3];
        const all = a0 ^ a1 ^ a2 ^ a3;
        s[c] ^= all ^ xtime(a0 ^ a1);
        s[c + 1] ^= all ^ xtime(a1 ^ a2);
        s[c + 2] ^= all ^ xtime(a2 ^ a3);
        s[c + 3] ^= all ^ xtime(a3 ^ a0);
      }
    }

    addRoundKey(round);
  }

  return s;
}

// --- GCM

// Multiplication in GF(2^128) of the GHASH, bit by bit (the links are short)
function gfMul(x: Uint8Array, y: Uint8Array): Uint8Array {
  const z = new Uint8Array(16);
  const v = new Uint8Array(y);

  for (let i = 0; i < 128; i++) {
    if ((x[i >> 3] >> (7 - (i & 7))) & 1) {
      for (let j = 0; j < 16; j++) {
        z[j] ^= v[j];
      }
    }

    const carry = v[15] & 1;

    for (let j = 15; j > 0; j--) {
      v[j] = (v[j] >> 1) | ((v[j - 1] & 1) << 7);
    }

    v[0] >>= 1;

    if (carry) {
      v[0] ^= 0xe1;
    }
  }

  return z;
}

function ghash(h: Uint8Array, data: Uint8Array): Uint8Array {
  let y: Uint8Array = new Uint8Array(16);

  for (let offset = 0; offset < data.length; offset += 16) {
    const block = new Uint8Array(16);
    block.set(data.subarray(offset, offset + 16));

    for (let i = 0; i < 16; i++) {
      y[i] ^= block[i];
    }

    y = gfMul(y, h);
  }

  return y;
}

function gcmDecrypt(
  key: Uint8Array,
  iv: Uint8Array,
  cipher: Uint8Array,
  tag: Uint8Array,
): Uint8Array | null {
  const roundKeys = expandKey(key);
  const h = encryptBlock(roundKeys, new Uint8Array(16));

  const counter = new Uint8Array(16);
  counter.set(iv);
  counter[15] = 1;

  // the tag first: nothing is returned from a message that does not authenticate
  const padded = new Uint8Array(Math.ceil(cipher.length / 16) * 16 + 16);
  padded.set(cipher);
  const lengths = new DataView(padded.buffer, padded.length - 16);
  lengths.setUint32(12, cipher.length * 8);
  const mask = encryptBlock(roundKeys, counter);
  const expected = ghash(h, padded);
  let diff = 0;

  for (let i = 0; i < TAG_LEN; i++) {
    diff |= expected[i] ^ mask[i] ^ tag[i];
  }

  if (diff !== 0) {
    return null;
  }

  const plain = new Uint8Array(cipher.length);

  for (let offset = 0; offset < cipher.length; offset += 16) {
    for (let i = 15; i >= 12; i--) {
      counter[i] = (counter[i] + 1) & 0xff;

      if (counter[i] !== 0) {
        break;
      }
    }

    const stream = encryptBlock(roundKeys, counter);
    const end = Math.min(16, cipher.length - offset);

    for (let i = 0; i < end; i++) {
      plain[offset + i] = cipher[offset + i] ^ stream[i];
    }
  }

  return plain;
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);

  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  }

  return out;
}

function base64UrlToBytes(value: string): Uint8Array | null {
  try {
    const padded = value.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
    const out = new Uint8Array(binary.length);

    for (let i = 0; i < binary.length; i++) {
      out[i] = binary.charCodeAt(i);
    }

    return out;
  } catch {
    return null;
  }
}

function utf8(bytes: Uint8Array): string | null {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

// http(s) with nothing in it that is a space or a control character (a line break would make
// one address of two on the router)
function isPlainHttpUrl(url: string): boolean {
  if (!/^https?:\/\/./i.test(url)) {
    return false;
  }

  for (let i = 0; i < url.length; i++) {
    const code = url.charCodeAt(i);

    if (code <= 0x20 || code === 0x7f) {
      return false;
    }
  }

  return true;
}

// The address (and the name, when there is one) inside an incy://crypt1/ link; null when the
// text is not such a link or does not authenticate.
export function decodeIncyLink(link: string): IncyLink | null {
  const text = link.trim();

  if (
    !text.toLowerCase().startsWith(LINK_PREFIX) ||
    text.length > MAX_LINK_LEN
  ) {
    return null;
  }

  const wire = base64UrlToBytes(
    text.slice(LINK_PREFIX.length).replace(/\/+$/, ''),
  );

  if (!wire || wire.length < IV_LEN + TAG_LEN + 1) {
    return null;
  }

  const plain = gcmDecrypt(
    hexToBytes(KEY_HEX),
    wire.subarray(0, IV_LEN),
    wire.subarray(IV_LEN, wire.length - TAG_LEN),
    wire.subarray(wire.length - TAG_LEN),
  );
  const json = plain ? utf8(plain) : null;

  if (json === null) {
    return null;
  }

  try {
    const parsed = JSON.parse(json) as { url?: unknown; n?: unknown };

    // The address goes on to wget and curl on the router: only http(s), and a single line.
    // The scheme is stored in lower case: the field check looks for "http://" / "https://".
    if (typeof parsed.url !== 'string' || !isPlainHttpUrl(parsed.url)) {
      return null;
    }

    const url = parsed.url.replace(/^[A-Za-z][A-Za-z0-9+.-]*:/, (scheme) =>
      scheme.toLowerCase(),
    );

    return typeof parsed.n === 'string' && parsed.n
      ? { url, name: parsed.n }
      : { url };
  } catch {
    return null;
  }
}

// Every incy:// link in a list of subscription addresses replaced by the address it holds;
// the rest is left as it is. `undecoded` counts the incy:// links that could not be read.
export function decodeIncyLinks(values: string[]): {
  values: string[];
  decoded: number;
  undecoded: number;
} {
  let decoded = 0;
  let undecoded = 0;

  const out = values.map((value) => {
    if (!isIncyLink(value)) {
      return value;
    }

    const link = decodeIncyLink(value);

    if (!link) {
      undecoded += 1;
      return value;
    }

    decoded += 1;
    return link.url;
  });

  return { values: out, decoded, undecoded };
}
