import { afterEach, describe, expect, it } from 'vitest';
import { validateAnytlsUrl, validateTuicUrl } from '../validateTuicAnytlsUrl';
import { validateProxyUrl } from '../validateProxyUrl';
import {
  UNKNOWN_CORE_CAPABILITIES,
  parseCoreCapabilities,
  setCoreCapabilities,
} from '../../helpers/coreCapabilities';

describe('validateTuicUrl', () => {
  it.each([
    'tuic://11111111-2222-3333-4444-555555555555:pw@example.com:443?alpn=h3#n',
    'tuic://11111111-2222-3333-4444-555555555555:pw@example.com',
    'tuic://u:p@203.0.113.9:8443',
  ])('accepts %s', (url) => {
    expect(validateTuicUrl(url).valid).toBe(true);
  });

  it.each([
    'tuic://example.com:443',
    'tuic://u:p@example.com:0',
    'tuic://u:p@exa mple.com',
    'tuic://u:p@bad_host!:443',
    'tuic://u:p@',
  ])('rejects %s', (url) => {
    expect(validateTuicUrl(url).valid).toBe(false);
  });
});

describe('validateAnytlsUrl', () => {
  it('accepts a link with a password', () => {
    expect(
      validateAnytlsUrl('anytls://secret@example.com:443?sni=x').valid,
    ).toBe(true);
  });

  it.each(['anytls://example.com:443', 'anytls://pw@example.com:70000'])(
    'rejects %s',
    (url) => {
      expect(validateAnytlsUrl(url).valid).toBe(false);
    },
  );
});

describe('the proxy URL validator', () => {
  afterEach(() => setCoreCapabilities({ ...UNKNOWN_CORE_CAPABILITIES }));

  it('knows tuic:// and anytls://', () => {
    expect(validateProxyUrl('tuic://u:p@example.com:443').valid).toBe(true);
    expect(validateProxyUrl('anytls://pw@example.com:443').valid).toBe(true);
  });

  it('refuses TUIC on a core without QUIC', () => {
    setCoreCapabilities(parseCoreCapabilities({ quic: false }));
    expect(validateProxyUrl('tuic://u:p@example.com:443').valid).toBe(false);
  });
});
