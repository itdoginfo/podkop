import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getDashboardSections } from '../getDashboardSections';
import { NetShiftShellMethods } from '../../shell';
import type { ClashAPI } from '../../../types';

// The services barrel starts TabService, which needs a DOM.
vi.mock('../../../services', async () => ({
  ...(await import('../../../services/store.service')),
  ...(await import('../../../services/logger.service')),
}));

// Sections with the links pasted as text ("Selector / URLTest (text list)") keep
// them in selector_proxy_links_text / urltest_proxy_links_text. The dashboard
// used to know only the list options and showed such a section empty.

function proxies(tags: string[]): Record<string, ClashAPI.ProxyBase> {
  return Object.fromEntries(
    tags.map((tag) => [
      tag,
      { type: 'Hysteria2', name: tag, udp: true, history: [] },
    ]),
  ) as Record<string, ClashAPI.ProxyBase>;
}

describe('getDashboardSections: text list sections', () => {
  beforeEach(() => {
    vi.stubGlobal('uci', {
      load: async () => undefined,
      sections: () => [
        {
          '.name': 'wg',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'urltest_text',
          urltest_proxy_links_text:
            'hy2://p@a.example:1#One\n\nhy2://p@b.example:2#Two\r\nfoo://x#Skipped\nhy2://p@c.example:3#Four\n',
        },
        {
          '.name': 'sel',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'selector_text',
          selector_proxy_links_text: 'hy2://p@a.example:1#A\nfoo://x#Bad',
        },
      ],
    });
    vi.spyOn(NetShiftShellMethods, 'getClashApiProxies').mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...proxies(['wg-1-out', 'wg-2-out', 'wg-4-out', 'sel-1-out']),
          'wg-urltest-out': {
            type: 'URLTest',
            name: 'wg-urltest-out',
            udp: true,
            history: [],
            all: ['wg-1-out', 'wg-2-out', 'wg-4-out'],
          },
          'wg-out': {
            type: 'Selector',
            name: 'wg-out',
            udp: true,
            history: [],
            now: 'wg-urltest-out',
            all: ['wg-1-out', 'wg-2-out', 'wg-4-out', 'wg-urltest-out'],
          },
          'sel-out': {
            type: 'Selector',
            name: 'sel-out',
            udp: true,
            history: [],
            now: 'sel-1-out',
            all: ['sel-1-out'],
          },
        },
      },
    } as Awaited<ReturnType<typeof NetShiftShellMethods.getClashApiProxies>>);
    vi.spyOn(NetShiftShellMethods, 'getGeoipFlags').mockResolvedValue({
      success: true,
      data: {},
    } as Awaited<ReturnType<typeof NetShiftShellMethods.getGeoipFlags>>);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('lists the servers of a URLTest text list, names matched by tag', async () => {
    const { data } = await getDashboardSections();
    const group = data.find((g) => g.displayName === 'wg')!;

    expect(group.withTagSelect).toBe(true);
    expect(group.outbounds.map((o) => o.code)).toEqual([
      'wg-urltest-out',
      'wg-1-out',
      'wg-2-out',
      'wg-4-out',
    ]);
    // The skipped third line must not shift the name of the fourth link.
    expect(group.outbounds.map((o) => o.displayName)).toEqual([
      'Fastest',
      'One',
      'Two',
      'Four',
    ]);
    expect(group.outbounds[0].selected).toBe(true);
  });

  it('numbers links like the backend: two links on one line are two servers', async () => {
    vi.stubGlobal('uci', {
      load: async () => undefined,
      sections: () => [
        {
          '.name': 'sel',
          '.type': 'section',
          connection_type: 'proxy',
          proxy_config_type: 'selector_text',
          selector_proxy_links_text:
            'hy2://p@a.example:1#A hy2://p@b.example:2#B',
        },
      ],
    });
    vi.spyOn(NetShiftShellMethods, 'getClashApiProxies').mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...proxies(['sel-1-out', 'sel-2-out']),
          'sel-out': {
            type: 'Selector',
            name: 'sel-out',
            udp: true,
            history: [],
            now: 'sel-1-out',
            all: ['sel-1-out', 'sel-2-out'],
          },
        },
      },
    } as Awaited<ReturnType<typeof NetShiftShellMethods.getClashApiProxies>>);

    const { data } = await getDashboardSections();

    expect(data[0].outbounds.map((o) => o.displayName)).toEqual(['A', 'B']);
  });

  it('lists the servers of a Selector text list, dropping skipped lines', async () => {
    const { data } = await getDashboardSections();
    const group = data.find((g) => g.displayName === 'sel')!;

    expect(group.outbounds.map((o) => o.displayName)).toEqual(['A']);
    expect(group.outbounds[0].selected).toBe(true);
  });
});
