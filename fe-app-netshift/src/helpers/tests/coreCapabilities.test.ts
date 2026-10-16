import { afterEach, describe, expect, it } from 'vitest';
import {
  UNKNOWN_CORE_CAPABILITIES,
  getCoreCapabilities,
  parseCoreCapabilities,
  setCoreCapabilities,
} from '../coreCapabilities';

describe('parseCoreCapabilities', () => {
  it('reads the answer of the backend', () => {
    const caps = parseCoreCapabilities(
      JSON.stringify({
        version: '1.12.22',
        variant: 'stock',
        quic: false,
        utls: true,
        naive: false,
        dns_pool: false,
        extended: false,
        vmess: false,
      }),
    );

    expect(caps.quic).toBe(false);
    expect(caps.dns_pool).toBe(false);
    expect(caps.vmess).toBe(false);
    expect(caps.utls).toBe(true);
    expect(caps.version).toBe('1.12.22');
  });

  it('believes the core able where the answer says nothing', () => {
    expect(parseCoreCapabilities({ quic: false }).utls).toBe(true);
    expect(parseCoreCapabilities({}).dns_pool).toBe(true);
  });

  it('survives garbage', () => {
    expect(parseCoreCapabilities('Usage: netshift')).toEqual(
      UNKNOWN_CORE_CAPABILITIES,
    );
    expect(parseCoreCapabilities(null)).toEqual(UNKNOWN_CORE_CAPABILITIES);
    expect(parseCoreCapabilities({ quic: 'no' }).quic).toBe(true);
  });
});

describe('the current capabilities', () => {
  afterEach(() => setCoreCapabilities({ ...UNKNOWN_CORE_CAPABILITIES }));

  it('are unknown (able) until set', () => {
    expect(getCoreCapabilities().quic).toBe(true);
  });

  it('can be set', () => {
    setCoreCapabilities(parseCoreCapabilities({ quic: false }));
    expect(getCoreCapabilities().quic).toBe(false);
  });
});
