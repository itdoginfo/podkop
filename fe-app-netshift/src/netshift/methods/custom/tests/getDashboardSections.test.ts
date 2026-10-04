import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getDashboardSections } from '../getDashboardSections';
import { NetShiftShellMethods } from '../../shell';
import type { ClashAPI } from '../../../types';

// The services barrel starts TabService, which needs a DOM.
vi.mock('../../../services', async () => ({
  ...(await import('../../../services/store.service')),
  ...(await import('../../../services/logger.service')),
}));

// The real getDashboardSections builds the groups from UCI sections and the Clash
// API proxies; only uci and the two shell calls are stubbed. The country flags the
// backend found for manually added links (keyed by outbound tag) end up in front of
// the names that have none.

const NL = '\u{1F1F3}\u{1F1F1}';
const DE = '\u{1F1E9}\u{1F1EA}';

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

function mockShell(flags: unknown, success = true) {
  vi.spyOn(NetShiftShellMethods, 'getClashApiProxies').mockResolvedValue({
    success: true,
    data: {
      proxies: proxies({
        'one-out': {},
        'sel-1-out': {},
        'sel-2-out': {},
        'sel-out': {
          type: 'Selector',
          now: 'sel-1-out',
          all: ['sel-1-out', 'sel-2-out'],
        },
      }),
    },
  } as Awaited<ReturnType<typeof NetShiftShellMethods.getClashApiProxies>>);
  vi.spyOn(NetShiftShellMethods, 'getGeoipFlags').mockResolvedValue({
    success,
    data: flags,
  } as Awaited<ReturnType<typeof NetShiftShellMethods.getGeoipFlags>>);
}

const names = (group: { outbounds: { displayName: string }[] }) =>
  group.outbounds.map((outbound) => outbound.displayName);

describe('getDashboardSections: GeoIP flags of manually added links', () => {
  beforeEach(() => {
    vi.stubGlobal('uci', {
      load: async () => undefined,
      sections: () => [
        {
          '.name': 'one',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'url',
          proxy_string: 'vless://u@a.example:443#Amsterdam',
        },
        {
          '.name': 'sel',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'selector',
          selector_proxy_links: [
            'vless://u@b.example:443#Berlin',
            `vless://u@c.example:443#${encodeURIComponent(DE)}%20Flagged`,
          ],
        },
      ],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('puts the flag found for a tag in front of the name', async () => {
    mockShell({ 'one-out': 'NL', 'sel-1-out': 'DE' });

    const { data } = await getDashboardSections();

    expect(names(data.find((g) => g.displayName === 'one')!)).toEqual([
      `${NL} Amsterdam`,
    ]);
    expect(names(data.find((g) => g.displayName === 'sel')!)[0]).toBe(
      `${DE} Berlin`,
    );
  });

  it('does not double a flag the name already has', async () => {
    mockShell({ 'sel-2-out': 'NL' });

    const { data } = await getDashboardSections();

    expect(names(data.find((g) => g.displayName === 'sel')!)[1]).toBe(
      `${DE} Flagged`,
    );
  });

  it('leaves names alone when there are no flags, or the call fails', async () => {
    mockShell({});
    expect(names((await getDashboardSections()).data[0])).toEqual([
      'Amsterdam',
    ]);

    mockShell('not an object', false);
    expect(names((await getDashboardSections()).data[0])).toEqual([
      'Amsterdam',
    ]);
  });
});
