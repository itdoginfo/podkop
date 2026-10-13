import { describe, expect, it } from 'vitest';
import {
  describeSubscriptionInfo,
  parseSubscriptionInfo,
  subscriptionInfoOf,
  type SubscriptionInfo,
} from '../subscriptionInfo';

const NOW = 1790000000;

const base: SubscriptionInfo = {
  upload: 1_000_000_000,
  download: 11_300_000_000,
  total: 100_000_000_000,
  expire: NOW + 25 * 86400,
  title: null,
};

describe('parseSubscriptionInfo', () => {
  it('reads the backend answer', () => {
    const parsed = parseSubscriptionInfo(
      JSON.stringify({ main: [{ ...base, title: 'VPN' }] }),
    );

    expect(parsed.main).toHaveLength(1);
    expect(parsed.main[0].total).toBe(100_000_000_000);
    expect(parsed.main[0].title).toBe('VPN');
  });

  it('accepts an already parsed object', () => {
    expect(parseSubscriptionInfo({ a: [{ total: 5 }] }).a[0].total).toBe(5);
  });

  it('drops what is not a number', () => {
    const parsed = parseSubscriptionInfo({
      a: [{ total: '5', upload: null }],
    });

    expect(parsed.a[0].total).toBeNull();
  });

  it('survives garbage', () => {
    expect(parseSubscriptionInfo('Usage: netshift')).toEqual({});
    expect(parseSubscriptionInfo(null)).toEqual({});
    expect(parseSubscriptionInfo([])).toEqual({});
    expect(parseSubscriptionInfo({ a: 'x' })).toEqual({});
  });
});

describe('describeSubscriptionInfo', () => {
  it('gives the usage, the share and the expiry', () => {
    const line = describeSubscriptionInfo(base, NOW);

    expect(line.used).toBe(12_300_000_000);
    expect(line.total).toBe(100_000_000_000);
    expect(line.percent).toBe(12);
    expect(line.expireDate).toBe(
      new Date((NOW + 25 * 86400) * 1000).toISOString().slice(0, 10),
    );
    expect(line.daysLeft).toBe(25);
    expect(line.exhausted).toBe(false);
  });

  it('treats a zero quota and a zero expiry as unlimited', () => {
    const line = describeSubscriptionInfo(
      { ...base, total: 0, expire: 0 },
      NOW,
    );

    expect(line.used).toBe(12_300_000_000);
    expect(line.total).toBeNull();
    expect(line.percent).toBeNull();
    expect(line.expireDate).toBeNull();
    expect(line.daysLeft).toBeNull();
    expect(line.exhausted).toBe(false);
  });

  it('flags an expired account', () => {
    const line = describeSubscriptionInfo(
      { ...base, expire: NOW - 3 * 86400 },
      NOW,
    );

    expect(line.daysLeft).toBe(-3);
    expect(line.exhausted).toBe(true);
  });

  it('flags used-up traffic and caps the share at 100', () => {
    const line = describeSubscriptionInfo(
      { ...base, download: 200_000_000_000 },
      NOW,
    );

    expect(line.percent).toBe(100);
    expect(line.exhausted).toBe(true);
  });

  it('has nothing to say when the panel reported nothing', () => {
    const line = describeSubscriptionInfo(
      { ...base, upload: null, download: null, total: null, expire: null },
      NOW,
    );

    expect(line.used).toBeNull();
    expect(line.expireDate).toBeNull();
    expect(line.exhausted).toBe(false);
  });

  it('counts the last partial day as a day left', () => {
    expect(
      describeSubscriptionInfo({ ...base, expire: NOW + 3600 }, NOW).daysLeft,
    ).toBe(1);
  });
});

describe('subscriptionInfoOf', () => {
  it('finds the info by the name of the section, not by the tag of its outbound', () => {
    const info = parseSubscriptionInfo({ main: [{ total: 7 }] });
    const group = { code: 'main-out', displayName: 'main' };

    expect(subscriptionInfoOf(info, group)).toHaveLength(1);
    expect(subscriptionInfoOf(info, group)[0].total).toBe(7);
    expect(info[group.code]).toBeUndefined();
  });

  it('gives an empty list for a section without info', () => {
    expect(subscriptionInfoOf({}, { displayName: 'other' })).toEqual([]);
  });
});
