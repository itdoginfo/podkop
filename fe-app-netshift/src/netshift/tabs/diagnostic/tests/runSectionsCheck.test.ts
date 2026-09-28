import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { runSectionsCheck } from '../checks/runSectionsCheck';
import { DIAGNOSTICS_CHECKS_MAP } from '../checks/contstants';
import { NetShiftShellMethods } from '../../../methods';
import { store } from '../../../services/store.service';
import type { ClashAPI } from '../../../types';

// The services barrel starts TabService, which needs a DOM; the check only
// uses the store from it.
vi.mock('../../../services', () => import('../../../services/store.service'));

// Wiring test: the real getDashboardSections builds the section from a
// UCI subscription section and Clash API proxies, and the real
// runSectionsCheck writes the result to the store. Only uci and the two
// Clash API calls are stubbed.

// Clash API reports every proxy under its tag, with name = tag.
function proxies(
  entries: Record<string, Partial<ClashAPI.ProxyBase>>,
): Record<string, ClashAPI.ProxyBase> {
  return Object.fromEntries(
    Object.entries(entries).map(([tag, patch]) => [
      tag,
      { type: 'VLESS', name: tag, udp: true, history: [], ...patch },
    ]),
  );
}

// Two subscriptions: the selector offers every node, a Fastest per
// subscription and the section-wide Fastest.
function twoFeedProxies(now: string) {
  return proxies({
    a1: {},
    a2: {},
    b1: {},
    '⚡ Feed A': { type: 'URLTest', now: 'a1', all: ['a1', 'a2'] },
    '⚡ Feed B': { type: 'URLTest', now: 'b1', all: ['b1'] },
    'main-urltest-out': {
      type: 'URLTest',
      now: 'a1',
      all: ['a1', 'a2', 'b1'],
    },
    'main-out': {
      type: 'Selector',
      now,
      all: ['a1', 'a2', 'b1', '⚡ Feed A', '⚡ Feed B', 'main-urltest-out'],
    },
  });
}

function mockProxies(now: string) {
  vi.spyOn(NetShiftShellMethods, 'getClashApiProxies').mockResolvedValue({
    success: true,
    data: { proxies: twoFeedProxies(now) },
  } as Awaited<ReturnType<typeof NetShiftShellMethods.getClashApiProxies>>);
}

// Clash API answers a delay test of a silent server with a message.
function mockClash(now: string, latency: Record<string, number>) {
  mockProxies(now);

  return vi
    .spyOn(NetShiftShellMethods, 'getClashApiProxyLatency')
    .mockImplementation(async (tag) => ({
      success: true,
      data: latency[tag]
        ? { delay: latency[tag] }
        : { delay: 0, message: 'An error occurred in the delay test' },
    }));
}

function outboundsCheck() {
  return store
    .get()
    .diagnosticsChecks.find(
      (item) => item.code === DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS.code,
    );
}

describe('runSectionsCheck with per-subscription blocks', () => {
  beforeEach(() => {
    vi.stubGlobal('uci', {
      load: async () => undefined,
      sections: () => [
        {
          '.name': 'main',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'subscription',
        },
      ],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('reports a per-subscription Fastest selected inside a block', async () => {
    // Clash API tests a urltest through the server it picked (b1).
    const probe = mockClash('⚡ Feed B', { '⚡ Feed B': 80 });

    await runSectionsCheck();

    expect(probe.mock.calls).toEqual([['⚡ Feed B']]);
    expect(outboundsCheck()?.state).toBe('success');
    expect(outboundsCheck()?.items).toEqual([
      { state: 'success', key: 'main', value: '[Fastest] 80ms' },
    ]);
  });

  it('probes only the section-wide Fastest, not every server', async () => {
    const probe = mockClash('main-urltest-out', {
      'main-urltest-out': 50,
      a1: 50,
      a2: 120,
      b1: 80,
    });

    await runSectionsCheck();

    expect(probe.mock.calls).toEqual([['main-urltest-out']]);
    expect(outboundsCheck()?.items).toEqual([
      { state: 'success', key: 'main', value: '[Fastest] 50ms' },
    ]);
  });

  it('reports the delay of a node selected inside a block', async () => {
    const probe = mockClash('a2', { a1: 50, a2: 120, b1: 80 });

    await runSectionsCheck();

    expect(probe.mock.calls).toEqual([['a2']]);
    expect(outboundsCheck()?.state).toBe('success');
    expect(outboundsCheck()?.items).toEqual([
      { state: 'success', key: 'main', value: '[a2] 120ms' },
    ]);
  });

  it('still reports a silent node selected inside a block', async () => {
    mockClash('a2', { a1: 50, b1: 80 });

    await expect(runSectionsCheck()).rejects.toThrow('Sections checks failed');

    expect(outboundsCheck()?.state).toBe('error');
    expect(outboundsCheck()?.items).toEqual([
      { state: 'error', key: 'main', value: '[a2] Not responding' },
    ]);
  });

  // The real shell call: a probe that never answers must end the check
  // with an error when the call times out, not leave it loading.
  it('reports a probe that times out', async () => {
    vi.useFakeTimers();
    mockProxies('a2');
    vi.stubGlobal('rpc', { declare: () => () => new Promise(() => undefined) });

    const check = expect(runSectionsCheck()).rejects.toThrow(
      'Sections checks failed',
    );

    await vi.advanceTimersByTimeAsync(15000);
    await check;

    expect(outboundsCheck()?.state).toBe('error');
    expect(outboundsCheck()?.items).toEqual([
      { state: 'error', key: 'main', value: '[a2] Not responding' },
    ]);

    vi.useRealTimers();
  });
});
