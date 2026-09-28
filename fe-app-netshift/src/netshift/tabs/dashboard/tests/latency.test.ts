import { describe, expect, it } from 'vitest';
import {
  getLatencyTargets,
  runWithConcurrency,
  setOutboundLatency,
} from '../latency';
import type { NetShift } from '../../../types';

function outbound(
  code: string,
  type = 'VLESS',
  latency = 0,
): NetShift.Outbound {
  return { code, displayName: code, latency, type, selected: false };
}

const subscriptionSection: NetShift.OutboundGroup = {
  withTagSelect: true,
  code: 'main-out',
  displayName: 'main',
  outbounds: [outbound('solo'), outbound('main-urltest-out', 'URLTest')],
  subgroups: [
    {
      code: '⚡ Feed A',
      displayName: 'Feed A',
      outbounds: [
        outbound('⚡ Feed A', 'URLTest'),
        outbound('a1'),
        outbound('a2'),
      ],
    },
    {
      code: '⚡ Feed B',
      displayName: 'Feed B',
      outbounds: [outbound('⚡ Feed B', 'URLTest'), outbound('b1', 'Trojan')],
    },
  ],
};

describe('getLatencyTargets', () => {
  it('probes every server of a selectable section, subgroups included', () => {
    expect(getLatencyTargets(subscriptionSection)).toEqual({
      probe: ['solo', 'a1', 'a2', 'b1'],
      groups: ['main-urltest-out', '⚡ Feed A', '⚡ Feed B'],
    });
  });

  it('probes the only outbound of a plain section', () => {
    expect(
      getLatencyTargets({
        withTagSelect: false,
        code: 'vpn-out',
        displayName: 'vpn',
        outbounds: [outbound('vpn-out', 'Direct')],
      }),
    ).toEqual({ probe: ['vpn-out'], groups: [] });
  });

  it('skips outbounds that Clash API did not report', () => {
    expect(
      getLatencyTargets({
        withTagSelect: true,
        code: 'sel-out',
        displayName: 'sel',
        outbounds: [outbound(''), outbound('sel-1-out'), outbound('sel-1-out')],
      }),
    ).toEqual({ probe: ['sel-1-out'], groups: [] });
  });
});

describe('setOutboundLatency', () => {
  it('updates the server wherever it is shown and nothing else', () => {
    const [next] = setOutboundLatency([subscriptionSection], 'a2', 321);

    expect(next.subgroups?.[0].outbounds.map((item) => item.latency)).toEqual([
      0, 0, 321,
    ]);
    expect(next.outbounds.every((item) => item.latency === 0)).toBe(true);
    expect(subscriptionSection.subgroups?.[0].outbounds[2].latency).toBe(0);
  });

  it('does not add subgroups to sections without them', () => {
    const { subgroups: _subgroups, ...plain } = subscriptionSection;
    const [next] = setOutboundLatency([plain], 'solo', 50);

    expect('subgroups' in next).toBe(false);
    expect(next.outbounds[0].latency).toBe(50);
  });
});

describe('runWithConcurrency', () => {
  it('keeps at most `limit` calls in flight and runs every item', async () => {
    let inFlight = 0;
    let peak = 0;
    const done: number[] = [];

    await runWithConcurrency([1, 2, 3, 4, 5, 6, 7], 3, async (item) => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await new Promise((resolve) => setTimeout(resolve, item % 3));
      inFlight -= 1;
      done.push(item);
    });

    expect(peak).toBe(3);
    expect(done.sort()).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  it('reports each result as soon as it is ready, not all at the end', async () => {
    const order: string[] = [];

    await runWithConcurrency([30, 1], 2, async (ms) => {
      await new Promise((resolve) => setTimeout(resolve, ms));
      order.push(`done ${ms}`);
    });

    expect(order).toEqual(['done 1', 'done 30']);
  });

  it('does nothing for an empty list', async () => {
    await expect(
      runWithConcurrency([], 4, async () => {
        throw new Error('must not run');
      }),
    ).resolves.toBeUndefined();
  });
});
