import { describe, expect, it } from 'vitest';
import {
  getCheckTag,
  getComponentCards,
  getSingBoxMutationWarningMessage,
  getSingBoxVariant,
  isSingBoxInstalled,
} from '../cards';

const emptyChecks = {
  netshift: { status: null, latest_version: '' },
  sing_box_stock: { status: null, latest_version: '' },
  sing_box_extended: { status: null, latest_version: '' },
  sing_box_extended_lite: { status: null, latest_version: '' },
  naive: { status: null, latest_version: '' },
};

function makeSystemInfo(patch = {}) {
  return {
    netshift_version: '1.0.0',
    netshift_latest_version: '1.0.0',
    sing_box_version: '1.12.0',
    sing_box_variant: 'stock',
    sing_box_lite_upx: 0,
    sing_box_lite_supported: 1,
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

describe('getSingBoxVariant', () => {
  it.each([
    ['stock', 'stock'],
    ['extended', 'extended'],
    ['extended_lite', 'extended_lite'],
  ])('passes the known variant %s through', (variant, expected) => {
    expect(
      getSingBoxVariant(makeSystemInfo({ sing_box_variant: variant })),
    ).toBe(expected);
  });

  it('falls back to stock for anything unknown (older backend)', () => {
    expect(
      getSingBoxVariant(makeSystemInfo({ sing_box_variant: 'weird' })),
    ).toBe('stock');
  });
});

describe('getSingBoxMutationWarningMessage', () => {
  it('maps the upx_ram_spike machine code to a translated message', () => {
    const message = getSingBoxMutationWarningMessage('upx_ram_spike');

    expect(message).not.toBe('upx_ram_spike');
    expect(message).toContain('UPX');
    expect(message).toContain('zram swap');
  });

  it('passes backend prose warnings through unchanged', () => {
    expect(getSingBoxMutationWarningMessage('apk world pins sing-box')).toBe(
      'apk world pins sing-box',
    );
  });
});

describe('getComponentCards', () => {
  it('always builds the cards in order: NetShift, the three cores, NaiveProxy', () => {
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);

    expect(cards.map((c) => c.key)).toEqual([
      'netshift',
      'sing_box_stock',
      'sing_box_extended',
      'sing_box_extended_lite',
      'naive',
    ]);
  });

  it('shows the stock card as installed/active when variant=stock', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_variant: 'stock', sing_box_version: '1.12.0' }),
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

  it('mirrors the layout when variant=extended', () => {
    const cards = getComponentCards(
      makeSystemInfo({
        sing_box_variant: 'extended',
        sing_box_version: '1.12.5',
      }),
      emptyChecks,
    );
    const [, stock, extended] = cards;

    expect(extended.installed).toBe(true);
    expect(extended.actions[0].backendAction).toBe('check_update');

    expect(stock.installed).toBe(false);
    expect(stock.actions[0].kind).toBe('switch');
    expect(stock.actions[0].backendAction).toBe('install_stable');
  });

  it('activates ONLY the lite card for a manually installed lite core', () => {
    // A hand-installed community lite (UPX layout) is detected by the backend
    // as extended_lite — the lite card must be the active one, NOT extended.
    const cards = getComponentCards(
      makeSystemInfo({
        sing_box_variant: 'extended_lite',
        sing_box_version: '1.14.1-extended-2.7.2-lite',
      }),
      emptyChecks,
    );
    const [, stock, extended, lite] = cards;

    expect(lite.key).toBe('sing_box_extended_lite');
    expect(lite.installed).toBe(true);
    expect(lite.version).toBe('1.14.1-extended-2.7.2-lite');
    expect(lite.actions[0].kind).toBe('check');
    expect(lite.actions[0].backendAction).toBe('check_update_lite');
    expect(lite.actions[0].loadingKey).toBe('singBoxExtendedLiteCheck');

    expect(extended.installed).toBe(false);
    expect(extended.actions[0].kind).toBe('switch');
    expect(stock.installed).toBe(false);
    expect(stock.actions[0].kind).toBe('switch');
  });

  it('offers switch-to-lite + Not installed when another core is active', () => {
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);
    const lite = cards[3];

    expect(lite.installed).toBe(false);
    expect(lite.version).toBe('Not installed');
    expect(lite.tag).toEqual({ label: 'Not installed', kind: 'neutral' });
    expect(lite.actions[0].kind).toBe('switch');
    expect(lite.actions[0].text).toBe('Switch to lite');
    expect(lite.actions[0].backendAction).toBe('install_extended_lite');
    expect(lite.actions[0].loadingKey).toBe('singBoxExtendedLiteAction');
    // Supported arch → actions enabled, no note.
    expect(lite.actionsDisabled).toBe(false);
    expect(lite.note).toBeUndefined();
  });

  it('turns an outdated lite check into an Install %s update action', () => {
    const cards = getComponentCards(
      makeSystemInfo({
        sing_box_variant: 'extended_lite',
        sing_box_version: '1.14.1-extended-2.7.2-lite',
      }),
      {
        ...emptyChecks,
        sing_box_extended_lite: {
          status: 'outdated',
          latest_version: '1.14.1-extended-2.7.3-lite',
        },
      },
    );
    const lite = cards[3];

    expect(lite.tag).toEqual({ label: 'Outdated', kind: 'warning' });
    expect(lite.actions[0].kind).toBe('update');
    expect(lite.actions[0].backendAction).toBe('install_extended_lite');
    expect(lite.actions[0].text).toBe('Install 1.14.1-extended-2.7.3-lite');
  });

  it('disables the lite card actions on an unsupported architecture', () => {
    const cards = getComponentCards(
      makeSystemInfo({ sing_box_lite_supported: 0 }),
      emptyChecks,
    );
    const lite = cards[3];

    // The card stays visible with its switch button, but disabled + note.
    expect(cards).toHaveLength(5);
    expect(lite.actions[0].kind).toBe('switch');
    expect(lite.actions[0].text).toBe('Switch to lite');
    expect(lite.actionsDisabled).toBe(true);
    expect(lite.note).toBe('Not available for your architecture');
  });

  it('adds the UPX badge + RAM footnote for a compressed lite install', () => {
    const cards = getComponentCards(
      makeSystemInfo({
        sing_box_variant: 'extended_lite',
        sing_box_lite_upx: 1,
        sing_box_version: '1.14.1-extended-2.7.2-lite',
      }),
      emptyChecks,
    );
    const lite = cards[3];

    expect(lite.extraTag).toEqual({ label: 'UPX', kind: 'warning' });
    expect(lite.note).toBe('Compressed build: uses more RAM at startup');
    expect(lite.actionsDisabled).toBe(false);
  });

  it('keeps core card descriptions contrasting extended vs lite sizes', () => {
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);

    expect(cards[2].description).toBe(
      'Extended core with all features (~105 MB)',
    );
    expect(cards[3].description).toBe(
      'Light build of the extended core for low-flash devices (~10 MB instead of ~105 MB)',
    );
    expect(cards[1].description).toBeUndefined();
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
      makeSystemInfo({ sing_box_variant: 'stock', sing_box_version: '1.12.0' }),
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

describe('the NaiveProxy card', () => {
  const card = (patch = {}, check = {}) =>
    getComponentCards(makeSystemInfo(patch), {
      ...emptyChecks,
      naive: { status: null, latest_version: '', ...check },
    }).find((item) => item.key === 'naive');

  it('is the last card', () => {
    const cards = getComponentCards(makeSystemInfo(), emptyChecks);

    expect(cards[cards.length - 1].key).toBe('naive');
  });

  it('offers to install when the client is not there', () => {
    const naive = card({ naive_version: 'not installed' });

    expect(naive.installed).toBe(false);
    expect(naive.actions.map((action) => action.kind)).toEqual([
      'naive_install',
    ]);
    expect(naive.tag).toEqual({ label: 'Not installed', kind: 'neutral' });
  });

  it('offers to check for updates, and to remove, when it is there', () => {
    const naive = card({ naive_version: '154.0.8037.49-4' });

    expect(naive.installed).toBe(true);
    expect(naive.version).toBe('154.0.8037.49-4');
    expect(naive.actions.map((action) => action.kind)).toEqual([
      'naive_check',
      'naive_remove',
    ]);
  });

  it('offers the newer release when the check found one', () => {
    const naive = card(
      { naive_version: '154.0.8037.49-4' },
      { status: 'outdated', latest_version: '155.0.1-1' },
    );

    expect(naive.actions.map((action) => action.kind)).toEqual([
      'naive_install',
      'naive_remove',
    ]);
    expect(naive.actions[0].text).toContain('155.0.1-1');
    expect(naive.tag).toEqual({ label: 'Outdated', kind: 'warning' });
  });

  it('treats a missing version as not installed', () => {
    expect(card({}).installed).toBe(false);
  });
});
