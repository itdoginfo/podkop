import { describe, expect, it } from 'vitest';
import { getSelectedOutbound } from '../helpers/getSelectedOutbound';
import { buildSubscriptionOutboundGroup } from '../../../methods/custom/buildSubscriptionOutboundGroup';
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

// Two subscriptions: the selector offers every node, a Fastest per
// subscription and the section-wide Fastest.
function twoFeedSection(now: string) {
  return buildSubscriptionOutboundGroup('main', [
    proxy('a1', 'VLESS'),
    proxy('a2', 'VLESS'),
    proxy('b1', 'VLESS'),
    proxy('⚡ Feed A', 'URLTest', { now: 'a1', all: ['a1', 'a2'] }),
    proxy('⚡ Feed B', 'URLTest', { now: 'b1', all: ['b1'] }),
    proxy('main-urltest-out', 'URLTest', {
      now: 'a1',
      all: ['a1', 'a2', 'b1'],
    }),
    proxy('main-out', 'Selector', {
      now,
      all: ['a1', 'a2', 'b1', '⚡ Feed A', '⚡ Feed B', 'main-urltest-out'],
    }),
  ]);
}

describe('getSelectedOutbound', () => {
  it('finds a per-subscription Fastest selected inside a block', () => {
    const selected = getSelectedOutbound(twoFeedSection('⚡ Feed B'));

    expect(selected?.code).toBe('⚡ Feed B');
    expect(selected?.type).toBe('URLTest');
  });

  it('finds a node selected inside a block', () => {
    const selected = getSelectedOutbound(twoFeedSection('a2'));

    expect(selected?.code).toBe('a2');
  });

  it('finds the section-wide Fastest at the top level', () => {
    const selected = getSelectedOutbound(twoFeedSection('main-urltest-out'));

    expect(selected?.code).toBe('main-urltest-out');
  });

  it('works for a section without blocks', () => {
    const selected = getSelectedOutbound({
      withTagSelect: true,
      code: 'main-out',
      displayName: 'main',
      outbounds: [
        {
          code: 'n1',
          displayName: 'n1',
          latency: 0,
          type: 'VLESS',
          selected: false,
        },
        {
          code: 'n2',
          displayName: 'n2',
          latency: 0,
          type: 'VLESS',
          selected: true,
        },
      ],
    });

    expect(selected?.code).toBe('n2');
  });
});
