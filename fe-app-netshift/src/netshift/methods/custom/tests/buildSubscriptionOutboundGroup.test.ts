import { describe, expect, it } from 'vitest';
import { buildSubscriptionOutboundGroup } from '../buildSubscriptionOutboundGroup';
import type { ClashAPI } from '../../../types';

type ProxyEntry = { code: string; value: ClashAPI.ProxyBase };

function proxy(
  code: string,
  type: string,
  patch: Partial<ClashAPI.ProxyBase> = {},
): ProxyEntry {
  return {
    code,
    value: { type, name: code, udp: true, history: [], ...patch },
  };
}

function node(code: string, delay = 0): ProxyEntry {
  return proxy(code, 'VLESS', {
    history: delay ? [{ time: '', delay }] : [],
  });
}

describe('buildSubscriptionOutboundGroup', () => {
  it('splits a multi-subscription section into per-subscription blocks', () => {
    const proxies = [
      node('a1', 120),
      node('a2'),
      node('b1', 300),
      proxy('⚡ Feed A', 'URLTest', { now: 'a1', all: ['a1', 'a2'] }),
      proxy('⚡ Feed B', 'URLTest', { now: 'b1', all: ['b1'] }),
      proxy('main-urltest-out', 'URLTest', {
        now: 'a1',
        all: ['a1', 'a2', 'b1'],
        history: [{ time: '', delay: 110 }],
      }),
      proxy('main-out', 'Selector', {
        now: '⚡ Feed B',
        all: ['a1', 'a2', 'b1', '⚡ Feed A', '⚡ Feed B', 'main-urltest-out'],
      }),
    ];

    const group = buildSubscriptionOutboundGroup('main', proxies);

    expect(group.code).toBe('main-out');
    expect(group.withTagSelect).toBe(true);
    expect(group.outbounds).toEqual([
      {
        code: 'main-urltest-out',
        displayName: 'Fastest',
        latency: 110,
        type: 'URLTest',
        selected: false,
      },
    ]);
    expect(group.subgroups).toEqual([
      {
        code: '⚡ Feed A',
        displayName: 'Feed A',
        outbounds: [
          {
            code: '⚡ Feed A',
            displayName: 'Fastest',
            latency: 0,
            type: 'URLTest',
            selected: false,
          },
          {
            code: 'a1',
            displayName: 'a1',
            latency: 120,
            type: 'VLESS',
            selected: false,
          },
          {
            code: 'a2',
            displayName: 'a2',
            latency: 0,
            type: 'VLESS',
            selected: false,
          },
        ],
      },
      {
        code: '⚡ Feed B',
        displayName: 'Feed B',
        outbounds: [
          {
            code: '⚡ Feed B',
            displayName: 'Fastest',
            latency: 0,
            type: 'URLTest',
            selected: true,
          },
          {
            code: 'b1',
            displayName: 'b1',
            latency: 300,
            type: 'VLESS',
            selected: false,
          },
        ],
      },
    ]);
  });

  it('keeps a single-subscription section flat', () => {
    const proxies = [
      node('a1'),
      node('a2'),
      proxy('main-urltest-out', 'URLTest', { all: ['a1', 'a2'] }),
      proxy('main-out', 'Selector', {
        now: 'a2',
        all: ['a1', 'a2', 'main-urltest-out'],
      }),
    ];

    const group = buildSubscriptionOutboundGroup('main', proxies);

    expect(group.subgroups).toBeUndefined();
    expect(
      group.outbounds.map((o) => [o.code, o.displayName, o.selected]),
    ).toEqual([
      ['main-urltest-out', 'Fastest', false],
      ['a1', 'a1', false],
      ['a2', 'a2', true],
    ]);
  });

  it('does not treat country groups as subscription blocks', () => {
    // Country mode: the selector holds the group urltests (whose members are
    // NOT selectable) and a cross-group urltest over those urltests.
    const proxies = [
      node('RU 1'),
      node('DE 1'),
      node('plain'),
      proxy('RU Fastest', 'URLTest', { all: ['RU 1'] }),
      proxy('DE Fastest', 'URLTest', { all: ['DE 1'] }),
      proxy('⚡ Fastest', 'URLTest', { all: ['RU Fastest', 'DE Fastest'] }),
      proxy('main-out', 'Selector', {
        now: '⚡ Fastest',
        all: ['⚡ Fastest', 'RU Fastest', 'DE Fastest', 'plain'],
      }),
    ];

    const group = buildSubscriptionOutboundGroup('main', proxies);

    expect(group.subgroups).toBeUndefined();
    expect(group.outbounds.map((o) => o.code)).toEqual([
      '⚡ Fastest',
      'RU Fastest',
      'DE Fastest',
      'plain',
    ]);
  });

  it('falls back to the legacy urltest members when the selector is empty', () => {
    const proxies = [
      node('a1'),
      proxy('main-urltest-out', 'URLTest', { all: ['a1'] }),
    ];

    const group = buildSubscriptionOutboundGroup('main', proxies);

    expect(group.code).toBe('main');
    expect(group.outbounds.map((o) => [o.code, o.displayName])).toEqual([
      ['main-urltest-out', 'Fastest'],
      ['a1', 'a1'],
    ]);
  });
});
