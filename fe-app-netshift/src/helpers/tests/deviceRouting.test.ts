import { describe, expect, it } from 'vitest';
import {
  DEVICE_ROUTE_DEFAULT,
  DEVICE_ROUTE_EXCLUDED,
  getDeviceRoute,
  listedDeviceIps,
  setDeviceRoute,
  toIpList,
} from '../deviceRouting';

const state = () => ({
  sections: {
    main: ['192.168.1.10'],
    second: ['192.168.1.20', '192.168.1.21'],
  },
  excluded: ['192.168.1.30'],
});

describe('DEVICE_ROUTE_EXCLUDED', () => {
  it('can not be the name of a UCI section', () => {
    // UCI section names are [A-Za-z0-9_]; the sentinel has a ':'
    expect(DEVICE_ROUTE_EXCLUDED).toMatch(/[^A-Za-z0-9_]/);
  });

  it('is not confused with a section called __excluded__', () => {
    const s = {
      sections: { __excluded__: ['10.0.0.1'] },
      excluded: ['10.0.0.2'],
    };

    expect(getDeviceRoute(s, '10.0.0.1')).toBe('__excluded__');
    expect(getDeviceRoute(s, '10.0.0.2')).toBe(DEVICE_ROUTE_EXCLUDED);
    expect(
      setDeviceRoute(s, '10.0.0.1', DEVICE_ROUTE_EXCLUDED).excluded,
    ).toEqual(['10.0.0.2', '10.0.0.1']);
  });
});

describe('toIpList', () => {
  it('keeps an array, trimmed and without blanks', () => {
    expect(toIpList([' 1.1.1.1 ', '', '2.2.2.2'])).toEqual([
      '1.1.1.1',
      '2.2.2.2',
    ]);
  });

  it('splits a string by spaces and commas', () => {
    expect(toIpList('1.1.1.1, 2.2.2.2  3.3.3.3')).toEqual([
      '1.1.1.1',
      '2.2.2.2',
      '3.3.3.3',
    ]);
  });

  it('gives an empty list for anything else', () => {
    expect(toIpList(undefined)).toEqual([]);
    expect(toIpList(null)).toEqual([]);
    expect(toIpList(5)).toEqual([]);
  });
});

describe('getDeviceRoute', () => {
  it('finds the section a device is fully routed through', () => {
    expect(getDeviceRoute(state(), '192.168.1.21')).toBe('second');
  });

  it('finds an excluded device', () => {
    expect(getDeviceRoute(state(), '192.168.1.30')).toBe(DEVICE_ROUTE_EXCLUDED);
  });

  it('is the default for an unlisted device', () => {
    expect(getDeviceRoute(state(), '192.168.1.99')).toBe(DEVICE_ROUTE_DEFAULT);
  });

  it('prefers a section over the excluded list if a config has both', () => {
    const both = { sections: { main: ['10.0.0.1'] }, excluded: ['10.0.0.1'] };
    expect(getDeviceRoute(both, '10.0.0.1')).toBe('main');
  });
});

describe('setDeviceRoute', () => {
  it('moves a device between sections', () => {
    const next = setDeviceRoute(state(), '192.168.1.10', 'second');
    expect(next.sections.main).toEqual([]);
    expect(next.sections.second).toEqual([
      '192.168.1.20',
      '192.168.1.21',
      '192.168.1.10',
    ]);
  });

  it('moves a section device to excluded and back to default', () => {
    const excluded = setDeviceRoute(
      state(),
      '192.168.1.10',
      DEVICE_ROUTE_EXCLUDED,
    );
    expect(excluded.sections.main).toEqual([]);
    expect(excluded.excluded).toEqual(['192.168.1.30', '192.168.1.10']);

    const back = setDeviceRoute(excluded, '192.168.1.10', DEVICE_ROUTE_DEFAULT);
    expect(back.excluded).toEqual(['192.168.1.30']);
    expect(getDeviceRoute(back, '192.168.1.10')).toBe(DEVICE_ROUTE_DEFAULT);
  });

  it('puts a new device into a section that has no list yet', () => {
    const next = setDeviceRoute(state(), '192.168.1.50', 'third');
    expect(next.sections.third).toEqual(['192.168.1.50']);
  });

  it('removes duplicates when moving', () => {
    const dup = { sections: { main: ['1.1.1.1', '1.1.1.1'] }, excluded: [] };
    expect(
      setDeviceRoute(dup, '1.1.1.1', DEVICE_ROUTE_DEFAULT).sections.main,
    ).toEqual([]);
  });

  it('does not change the input state', () => {
    const input = state();
    setDeviceRoute(input, '192.168.1.10', DEVICE_ROUTE_EXCLUDED);
    expect(input).toEqual(state());
  });
});

describe('listedDeviceIps', () => {
  it('lists every IP once, sections first', () => {
    const input = {
      sections: { main: ['1.1.1.1', '2.2.2.2'], second: ['2.2.2.2'] },
      excluded: ['3.3.3.3', '1.1.1.1'],
    };
    expect(listedDeviceIps(input)).toEqual(['1.1.1.1', '2.2.2.2', '3.3.3.3']);
  });
});
