import { describe, expect, it } from 'vitest';
import { getEnvironmentItems } from '../helpers/getEnvironmentItems';
import type { NetShift } from '../../../types';

const clean: NetShift.EnvironmentCheckResult = {
  flow_offloading: { software: false, hardware: false, active: false },
  clock: {
    plausible: true,
    skew_seconds: 2,
    ntp_enabled: true,
    timezone: 'UTC',
  },
  ipv6: { router_has_global: false, netshift_enabled: false },
};

const states = (data: NetShift.EnvironmentCheckResult) =>
  getEnvironmentItems(data).map((item) => item.state);

describe('getEnvironmentItems', () => {
  it('is all green on a clean router', () => {
    expect(states(clean)).toEqual(['success', 'success', 'success']);
  });

  it('warns about any kind of flow offloading', () => {
    for (const flow of [
      { software: true, hardware: false, active: false },
      { software: false, hardware: true, active: false },
      { software: false, hardware: false, active: true },
    ]) {
      expect(states({ ...clean, flow_offloading: flow })[0]).toBe('warning');
    }
  });

  it('fails on an impossible clock and warns on a skewed one', () => {
    expect(
      states({ ...clean, clock: { ...clean.clock, plausible: false } })[1],
    ).toBe('error');
    expect(
      states({ ...clean, clock: { ...clean.clock, skew_seconds: 301 } })[1],
    ).toBe('warning');
    expect(
      states({ ...clean, clock: { ...clean.clock, skew_seconds: -900 } })[1],
    ).toBe('warning');
    expect(
      states({ ...clean, clock: { ...clean.clock, skew_seconds: 300 } })[1],
    ).toBe('success');
    expect(
      states({ ...clean, clock: { ...clean.clock, skew_seconds: null } })[1],
    ).toBe('success');
  });

  it('warns about global IPv6 with IPv6 handling off only', () => {
    expect(
      states({
        ...clean,
        ipv6: { router_has_global: true, netshift_enabled: false },
      })[2],
    ).toBe('warning');
    expect(
      states({
        ...clean,
        ipv6: { router_has_global: true, netshift_enabled: true },
      })[2],
    ).toBe('success');
  });
});
