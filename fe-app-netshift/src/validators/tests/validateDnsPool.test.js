import { describe, expect, it } from 'vitest';
import { DNS_POOL_PRESETS } from '../../constants';
import {
  validateDnsPoolServer,
  validateDnsPoolTimeout,
} from '../validateDnsPool.js';

const validServers = [
  ['UDP IP', 'udp://77.88.8.8'],
  ['UDP IP with port', 'udp://77.88.8.8:5353'],
  ['TCP IP', 'tcp://1.1.1.1'],
  ['DoT domain', 'dot://dns.quad9.net'],
  ['DoT domain with port', 'dot://dns.quad9.net:853'],
  ['DoH domain with path', 'doh://dns.google/dns-query'],
  ['DoH IP with path', 'doh://1.1.1.1/dns-query'],
  ['DoH3 domain with path', 'doh3://dns.adguard-dns.com/dns-query'],
  ['DoQ domain', 'doq://dns.adguard-dns.com'],
  ['bracketed IPv6', 'udp://[2001:db8::1]'],
  ['bracketed IPv6 with port', 'dot://[2001:db8::1]:853'],
];

const invalidServers = [
  ['empty', ''],
  ['no scheme', '8.8.8.8'],
  ['unknown scheme', 'https://dns.google/dns-query'],
  ['path on udp', 'udp://8.8.8.8/dns-query'],
  ['path on dot', 'dot://dns.quad9.net/dns-query'],
  ['spaces', 'udp://8.8.8.8 '],
  ['empty host', 'udp://'],
  ['bad host', 'udp://not_a_host'],
];

describe('validateDnsPoolServer', () => {
  describe.each(validServers)('Valid DNS pool server: %s', (_desc, value) => {
    it(`returns valid=true for "${value}"`, () => {
      expect(validateDnsPoolServer(value).valid).toBe(true);
    });
  });

  describe.each(invalidServers)(
    'Invalid DNS pool server: %s',
    (_desc, value) => {
      it(`returns valid=false for "${value}"`, () => {
        expect(validateDnsPoolServer(value).valid).toBe(false);
      });
    },
  );
});

describe('validateDnsPoolTimeout', () => {
  it.each(['500ms', '2s', '10s', '1ms'])('accepts %s', (value) => {
    expect(validateDnsPoolTimeout(value).valid).toBe(true);
  });

  it.each(['', '0s', '2', 's', '1.5s', '2m', '-1s', '2 s'])(
    'rejects "%s"',
    (value) => {
      expect(validateDnsPoolTimeout(value).valid).toBe(false);
    },
  );
});

describe('DNS_POOL_PRESETS', () => {
  it.each(Object.keys(DNS_POOL_PRESETS))('%s is a valid entry', (value) => {
    expect(validateDnsPoolServer(value).valid).toBe(true);
  });

  it('offers every transport the pool understands', () => {
    const schemes = new Set(
      Object.keys(DNS_POOL_PRESETS).map((value) => value.split('://')[0]),
    );

    expect([...schemes].sort()).toEqual(
      ['doh', 'doh3', 'doq', 'dot', 'tcp', 'udp'].sort(),
    );
  });
});
