import { describe, expect, it } from 'vitest';
import { getCheckTag, getComponentCards, isSingBoxInstalled } from '../cards';

const emptyChecks = {
  netshift: { status: null, latest_version: '' },
  sing_box_stock: { status: null, latest_version: '' },
  sing_box_extended: { status: null, latest_version: '' },
};

function makeSystemInfo(patch = {}) {
  return {
    netshift_version: '1.0.0',
    netshift_latest_version: '1.0.0',
    sing_box_version: '1.12.0',
    sing_box_extended: 0,
    ...patch,
  };
}

describe('getCheckTag', () => {
  it.each([
    ['latest', { label: 'Latest', kind: 'success' }],
    ['outdated', { label: 'Outdated', kind: 'warning' }],
    ['dev', { label: 'Dev', kind: 'neutral' }],
    ['not_installed', { label: 'Not installed', kind: 'neutral' }],
  ])('maps status %s to the right badge', (status, expected) => {
    expect(getCheckTag(status)).toEqual(expected);
  });

  it('returns undefined for a null status', () => {
    expect(getCheckTag(null)).toBeUndefined();
  });
});

describe('isSingBoxInstalled', () => {
  it.each([
    ['1.12.0', true],
    ['not installed', false],
    ['', false],
  ])('treats %s as installed=%s', (version, expected) => {
    expect(
      isSingBoxInstalled(makeSystemInfo({ sing_box_version: version })),
    ).toBe(expected);
  });
});

describe('getComponentCards', () => {
  it('always builds exactly three cards in order', () => {
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);

    expect(cards.map((c) => c.key)).toEqual([
      'netshift',
      'sing_box_stock',
      'sing_box_extended',
    ]);
  });

  it('shows the stock card as installed/active when sing_box_extended=0', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_extended: 0, sing_box_version: '1.12.0' }),
      emptyChecks,
    );
    const [, stock, extended] = cards;

    expect(stock.installed).toBe(true);
    expect(stock.version).toBe('1.12.0');
    // No check yet → no badge for the active card.
    expect(stock.tag).toBeUndefined();
    expect(stock.actions[0].kind).toBe('check');
    expect(stock.actions[0].backendAction).toBe('check_update_stable');

    // Inactive extended card → "Not installed" + switch-to-extended.
    expect(extended.installed).toBe(false);
    expect(extended.version).toBe('Not installed');
    expect(extended.actions[0].kind).toBe('switch');
    expect(extended.actions[0].backendAction).toBe('install_extended');
  });

  it('mirrors the layout when sing_box_extended=1', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_extended: 1, sing_box_version: '1.12.5' }),
      emptyChecks,
    );
    const [, stock, extended] = cards;

    expect(extended.installed).toBe(true);
    expect(extended.actions[0].backendAction).toBe('check_update');

    expect(stock.installed).toBe(false);
    expect(stock.actions[0].kind).toBe('switch');
    expect(stock.actions[0].backendAction).toBe('install_stable');
  });

  it('offers switch-to on both cores when sing-box is absent', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_version: 'not installed' }),
      emptyChecks,
    );
    const [, stock, extended] = cards;

    expect(stock.installed).toBe(false);
    expect(stock.actions[0].kind).toBe('switch');
    expect(extended.installed).toBe(false);
    expect(extended.actions[0].kind).toBe('switch');
  });

  it('turns an outdated stock check into an Install %s update action', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_extended: 0, sing_box_version: '1.12.0' }),
      {
        ...emptyChecks,
        sing_box_stock: { status: 'outdated', latest_version: '1.12.9' },
      },
    );
    const stock = cards[1];

    expect(stock.tag).toEqual({ label: 'Outdated', kind: 'warning' });
    expect(stock.actions[0].kind).toBe('update');
    expect(stock.actions[0].backendAction).toBe('install_stable');
    expect(stock.actions[0].text).toBe('Install 1.12.9');
  });

  it('is neutral until checked — null managerChecks.netshift status', () => {
    // task-030: mount does NO network check; managerChecks.netshift.status is
    // null → no badge, the "Check update" action (no outdated/update button).
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);
    const netshift = cards[0];

    expect(netshift.tag).toBeUndefined();
    expect(netshift.actions[0].kind).toBe('check_netshift');
    expect(netshift.actions[0].backendAction).toBe('check_update');
  });

  it('derives an outdated NetShift card from the on-demand check result', () => {
    // task-030: status comes from managerChecks.netshift (the check result), NOT
    // from a systemInfo installed-vs-latest string compare. The latest_version
    // for the "Install %s" text also comes from the check result.
    const cards = getComponentCards(
      makeSystemInfo({
        netshift_version: '1.0.0',
        netshift_latest_version: '1.0.0',
      }),
      {
        ...emptyChecks,
        netshift: { status: 'outdated', latest_version: '1.1.0' },
      },
    );
    const netshift = cards[0];

    expect(netshift.tag).toEqual({ label: 'Outdated', kind: 'warning' });
    expect(netshift.actions[0].kind).toBe('self_update');
    expect(netshift.actions[0].backendAction).toBe('self_update');
    expect(netshift.actions[0].text).toBe('Install 1.1.0');
  });

  it('shows the Latest badge + Check update when the check says latest', () => {
    const cards = getComponentCards(makeSystemInfo(), {
      ...emptyChecks,
      netshift: { status: 'latest', latest_version: '1.0.0' },
    });
    const netshift = cards[0];

    expect(netshift.tag).toEqual({ label: 'Latest', kind: 'success' });
    // The NetShift check is a DISTINCT kind so it can never be routed to the
    // sing-box check method.
    expect(netshift.actions[0].kind).toBe('check_netshift');
  });

  it('NetShift check action carries its own (non-sing-box) backendAction', () => {
    // The NetShift "Check update" routes to runNetshiftCheck (distinct kind) and
    // calls `component_action netshift check_update` — NOT a sing-box check
    // action. Guard against accidentally reusing a sing-box check action.
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);
    const netshift = cards[0];

    expect(netshift.actions[0].kind).toBe('check_netshift');
    expect(netshift.actions[0].backendAction).toBe('check_update');
    expect(['check_update_stable']).not.toContain(
      netshift.actions[0].backendAction,
    );
  });

  it('keeps a dev build neutral even if a check result says outdated', () => {
    // The dev-build guard: a placeholder/dev install never shows an update
    // prompt regardless of any check result.
    const cards = getComponentCards(
      makeSystemInfo({ netshift_version: 'COMPILED_VERSION' }),
      {
        ...emptyChecks,
        netshift: { status: 'outdated', latest_version: '9.9.9' },
      },
    );
    const netshift = cards[0];

    expect(netshift.version).toBe('dev');
    expect(netshift.tag).toBeUndefined();
    expect(netshift.actions[0].kind).toBe('check_netshift');
  });

  it('ignores systemInfo netshift_latest_version for status (now on-demand)', () => {
    // task-030: a stale/unknown systemInfo latest must NOT drive the badge — only
    // the on-demand managerChecks.netshift result does.
    const cards = getComponentCards(
      makeSystemInfo({
        netshift_version: '1.0.0',
        netshift_latest_version: '9.9.9',
      }),
      emptyChecks,
    );
    const netshift = cards[0];

    expect(netshift.tag).toBeUndefined();
    expect(netshift.actions[0].kind).toBe('check_netshift');
  });
});
