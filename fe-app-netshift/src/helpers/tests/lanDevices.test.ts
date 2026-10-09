import { describe, expect, it } from 'vitest';
import {
  deviceMatchesQuery,
  findStaticLease,
  isIpv4InSubnet,
  isLanIpv4,
  isValidMac,
  parseLanInfo,
} from '../lanDevices';

describe('isIpv4InSubnet', () => {
  it.each([
    ['192.168.1.77', '192.168.1.0/24', true],
    ['192.168.2.1', '192.168.1.0/24', false],
    ['10.8.200.9', '10.8.0.0/16', true],
    ['5.23.104.2', '192.168.1.0/24', false],
    ['0.0.0.0', '0.0.0.0/0', true],
    ['255.255.255.255', '0.0.0.0/0', true],
    ['192.168.1.1', '192.168.1.1/32', true],
    ['192.168.1.2', '192.168.1.1/32', false],
    ['192.168.1.1', '192.168.1.0/33', false],
    ['192.168.1.1', '192.168.1.0', false],
    ['999.1.1.1', '192.168.1.0/24', false],
    ['not-an-ip', '192.168.1.0/24', false],
  ])('%s in %s = %s', (ip, subnet, expected) => {
    expect(isIpv4InSubnet(ip, subnet)).toBe(expected);
  });
});

describe('isLanIpv4', () => {
  it('uses the subnets', () => {
    expect(isLanIpv4('192.168.1.5', ['192.168.1.0/24'])).toBe(true);
    expect(isLanIpv4('5.23.104.2', ['192.168.1.0/24'])).toBe(false);
  });

  it('accepts any address when the subnets are unknown', () => {
    expect(isLanIpv4('5.23.104.2', [])).toBe(true);
  });

  it('rejects an empty address either way', () => {
    expect(isLanIpv4('', [])).toBe(false);
    expect(isLanIpv4(null, ['192.168.1.0/24'])).toBe(false);
  });
});

describe('parseLanInfo', () => {
  it('reads subnets and static leases', () => {
    const info = parseLanInfo(
      JSON.stringify({
        subnets: ['192.168.1.0/24'],
        static_hosts: [
          {
            section: 'a',
            macs: ['aa:bb:cc:00:00:01'],
            ip: '192.168.1.20',
            name: 'printer',
          },
          {
            section: 'b',
            macs: ['AA:BB:CC:00:00:02', 'AA:BB:CC:00:00:03'],
            ip: '192.168.1.30',
          },
          { section: 'broken' },
        ],
      }),
    );

    expect(info.subnets).toEqual(['192.168.1.0/24']);
    expect(info.staticHosts).toHaveLength(2);
    expect(findStaticLease(info, 'aa:bb:cc:00:00:01')?.name).toBe('printer');
    expect(findStaticLease(info, 'aa:bb:cc:00:00:03')?.section).toBe('b');
    expect(findStaticLease(info, 'aa:bb:cc:00:00:99')).toBeUndefined();
  });

  it('survives garbage', () => {
    expect(parseLanInfo('Usage: netshift ...')).toEqual({
      subnets: [],
      staticHosts: [],
    });
    expect(parseLanInfo('{}')).toEqual({ subnets: [], staticHosts: [] });
    expect(parseLanInfo('')).toEqual({ subnets: [], staticHosts: [] });
  });
});

describe('deviceMatchesQuery', () => {
  const device = {
    name: 'Admin-PC',
    ip: '192.168.1.103',
    mac: '34:5A:60:6E:E3:46',
  };

  it.each([
    ['', true],
    ['admin', true],
    ['1.103', true],
    ['5a:60', true],
    ['phone', false],
  ])('%j -> %s', (query, expected) => {
    expect(deviceMatchesQuery(device, query)).toBe(expected);
  });
});

describe('isValidMac', () => {
  it('checks the colon form', () => {
    expect(isValidMac('aa:bb:cc:00:11:22')).toBe(true);
    expect(isValidMac('aa-bb-cc-00-11-22')).toBe(false);
    expect(isValidMac('aa:bb:cc:00:11')).toBe(false);
  });
});
