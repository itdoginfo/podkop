import { NetShift } from '../../types';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';

export type ManagerComponentKey =
  | 'netshift'
  | 'sing_box_stock'
  | 'sing_box_extended'
  | 'sing_box_extended_lite'
  | 'naive';

// `check` = a sing-box update check (routed to the sing-box check method);
// `check_netshift` = the NetShift card's on-demand check (task-030), which now
// calls the dedicated `component_action netshift check_update` action and writes
// `managerChecks.netshift` — exactly like the sing-box cores. Keeping it a
// DISTINCT kind guarantees a NetShift check can never be routed to the sing-box
// check method (the dispatcher routes it to runNetshiftCheck).
export type ManagerActionKind =
  | 'check'
  | 'check_netshift'
  | 'update'
  | 'switch'
  | 'self_update'
  | 'naive_check'
  | 'naive_install'
  | 'naive_remove';

export interface ManagerActionDescriptor {
  // The store-slice key driving this button's loading flag.
  loadingKey:
    | 'netshiftCheck'
    | 'netshiftUpdate'
    | 'singBoxStockCheck'
    | 'singBoxStockAction'
    | 'singBoxExtendedCheck'
    | 'singBoxExtendedAction'
    | 'singBoxExtendedLiteCheck'
    | 'singBoxExtendedLiteAction'
    | 'naiveCheck'
    | 'naiveAction';
  kind: ManagerActionKind;
  text: string;
  // For `update`/`switch`: the backend install action; for `self_update`:
  // 'self_update'; for `check`: the sing-box check action; for `check_netshift`:
  // the NetShift check action (routed to the dedicated NetShift check method).
  backendAction?:
    | 'check_update'
    | 'check_update_stable'
    | 'check_update_lite'
    | 'install_stable'
    | 'install_extended'
    | 'install_extended_lite'
    | 'self_update';
}

export interface ManagerCardTag {
  label: string;
  kind: 'neutral' | 'success' | 'warning';
}

export interface ManagerCardDescriptor {
  key: ManagerComponentKey;
  title: string;
  // One-line muted summary under the header (size hints for the cores).
  description?: string;
  version: string;
  installed: boolean;
  tag?: ManagerCardTag;
  // Extra badge rendered next to `tag` (e.g. the lite card's UPX marker).
  extraTag?: ManagerCardTag;
  // Muted footnote under the actions (unsupported-arch / UPX RAM caveat).
  note?: string;
  // Disables every action of the card (e.g. lite on an unsupported arch).
  actionsDisabled?: boolean;
  actions: ManagerActionDescriptor[];
}

export type ManagerSystemInfo = {
  netshift_version: string;
  netshift_latest_version: string;
  sing_box_version: string;
  // Active core flavour — the single source of truth for card activity
  // (replaces the old sing_box_extended bit, which stayed 0|1 and could not
  // tell a lite install from a stock one).
  sing_box_variant: NetShift.SingBoxVariant;
  sing_box_lite_upx: 0 | 1;
  sing_box_lite_supported: 0 | 1;
  // Release of the NaiveProxy client, "not installed" or "unknown".
  naive_version?: string;
};

export type ManagerCheckState = {
  status: NetShift.ComponentUpdateStatus | null;
  latest_version: string;
};

const NOT_INSTALLED = 'not installed';

export function isSingBoxInstalled(systemInfo: ManagerSystemInfo): boolean {
  const version = systemInfo.sing_box_version;

  return Boolean(version) && version !== NOT_INSTALLED;
}

const SING_BOX_VARIANTS: NetShift.SingBoxVariant[] = [
  'stock',
  'extended',
  'extended_lite',
];

/**
 * Defensive variant read: an older backend (or a failed fetch fallback) may
 * carry an unknown/missing sing_box_variant — anything unrecognized maps to
 * 'stock' so exactly one core card stays active at any time.
 */
export function getSingBoxVariant(
  systemInfo: ManagerSystemInfo,
): NetShift.SingBoxVariant {
  return SING_BOX_VARIANTS.includes(systemInfo.sing_box_variant)
    ? systemInfo.sing_box_variant
    : 'stock';
}

/**
 * Map a machine-readable install warning code to a translatable message.
 * Only 'upx_ram_spike' is a code; anything else is already human-readable
 * backend prose (e.g. the apk-world pin note) and passes through unchanged.
 */
export function getSingBoxMutationWarningMessage(warning: string): string {
  if (warning === 'upx_ram_spike') {
    return _(
      'UPX-compressed core: a RAM spike is possible at startup; on devices with less than 256 MB of RAM, enable zram swap',
    );
  }

  return warning;
}

/**
 * Map a check status to a status badge. Pure — same logic as podkop-plus
 * `getCheckTag`, extended with `not_installed`.
 */
export function getCheckTag(
  status: NetShift.ComponentUpdateStatus | null,
): ManagerCardTag | undefined {
  if (!status) {
    return undefined;
  }

  if (status === 'latest') {
    return { label: _('Latest'), kind: 'success' };
  }

  if (status === 'outdated') {
    return { label: _('Outdated'), kind: 'warning' };
  }

  if (status === 'not_installed') {
    return { label: _('Not installed'), kind: 'neutral' };
  }

  return { label: _('Dev'), kind: 'neutral' };
}

// NetShift status is derived from the on-demand check result (task-030):
// `managerChecks.netshift.status` is null until the user presses "Check update"
// → neutral card (no badge, no update button). The backend already computes the
// v-normalized status, so we TRUST it (no installed-vs-latest string compare).
// The `dev`-build guard is kept locally: a dev/placeholder build never shows an
// update prompt regardless of any check result.
function netshiftStatus(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): NetShift.ComponentUpdateStatus | null {
  const installed = normalizeCompiledVersion(systemInfo.netshift_version);

  if (installed === 'dev') {
    return null;
  }

  return check.status;
}

function netshiftCard(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): ManagerCardDescriptor {
  const status = netshiftStatus(systemInfo, check);
  const latest = check.latest_version;
  const actions: ManagerActionDescriptor[] = [];

  if (status === 'outdated') {
    actions.push({
      loadingKey: 'netshiftUpdate',
      kind: 'self_update',
      text: latest
        ? _('Install %s').replace('%s', latest)
        : _('Update NetShift'),
      backendAction: 'self_update',
    });
  } else {
    actions.push({
      loadingKey: 'netshiftCheck',
      kind: 'check_netshift',
      text: _('Check update'),
      backendAction: 'check_update',
    });
  }

  return {
    key: 'netshift',
    title: 'NetShift',
    version: normalizeCompiledVersion(systemInfo.netshift_version),
    installed: true,
    tag: getCheckTag(status),
    actions,
  };
}

function singBoxStockCard(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): ManagerCardDescriptor {
  const installed = isSingBoxInstalled(systemInfo);
  const isActive = installed && getSingBoxVariant(systemInfo) === 'stock';
  const actions: ManagerActionDescriptor[] = [];

  if (isActive) {
    if (check.status === 'outdated') {
      const latest = check.latest_version;

      actions.push({
        loadingKey: 'singBoxStockAction',
        kind: 'update',
        text: latest ? _('Install %s').replace('%s', latest) : _('Update'),
        backendAction: 'install_stable',
      });
    } else {
      actions.push({
        loadingKey: 'singBoxStockCheck',
        kind: 'check',
        text: _('Check update'),
        backendAction: 'check_update_stable',
      });
    }
  } else {
    // Either extended is active, or no sing-box at all → offer switch-to-stable.
    actions.push({
      loadingKey: 'singBoxStockAction',
      kind: 'switch',
      text: _('Switch to stable'),
      backendAction: 'install_stable',
    });
  }

  return {
    key: 'sing_box_stock',
    title: 'sing-box (stock)',
    version: isActive ? systemInfo.sing_box_version : _('Not installed'),
    installed: isActive,
    tag: isActive ? getCheckTag(check.status) : getCheckTag('not_installed'),
    actions,
  };
}

function singBoxExtendedCard(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): ManagerCardDescriptor {
  const installed = isSingBoxInstalled(systemInfo);
  const isActive = installed && getSingBoxVariant(systemInfo) === 'extended';
  const actions: ManagerActionDescriptor[] = [];

  if (isActive) {
    if (check.status === 'outdated') {
      const latest = check.latest_version;

      actions.push({
        loadingKey: 'singBoxExtendedAction',
        kind: 'update',
        text: latest ? _('Install %s').replace('%s', latest) : _('Update'),
        backendAction: 'install_extended',
      });
    } else {
      actions.push({
        loadingKey: 'singBoxExtendedCheck',
        kind: 'check',
        text: _('Check update'),
        backendAction: 'check_update',
      });
    }
  } else {
    actions.push({
      loadingKey: 'singBoxExtendedAction',
      kind: 'switch',
      text: _('Switch to extended'),
      backendAction: 'install_extended',
    });
  }

  return {
    key: 'sing_box_extended',
    title: 'sing-box (extended)',
    description: _('Extended core with all features (~105 MB)'),
    version: isActive ? systemInfo.sing_box_version : _('Not installed'),
    installed: isActive,
    tag: isActive ? getCheckTag(check.status) : getCheckTag('not_installed'),
    actions,
  };
}

// sing-box (extended lite): the third core flavour — a light build of the
// extended core (~10 MB vs ~105 MB) for routers with little flash. Visible
// even on unsupported architectures, but with disabled actions + a note;
// active ⇔ sing_box_variant === 'extended_lite' (covers our installs AND the
// community manual UPX layouts the backend detects). A UPX-compressed install
// additionally carries the UPX badge + a RAM-footnote.
function singBoxExtendedLiteCard(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): ManagerCardDescriptor {
  const installed = isSingBoxInstalled(systemInfo);
  const isActive =
    installed && getSingBoxVariant(systemInfo) === 'extended_lite';
  const supported = systemInfo.sing_box_lite_supported === 1;
  const upx = systemInfo.sing_box_lite_upx === 1;
  const actions: ManagerActionDescriptor[] = [];

  if (isActive) {
    if (check.status === 'outdated') {
      const latest = check.latest_version;

      actions.push({
        loadingKey: 'singBoxExtendedLiteAction',
        kind: 'update',
        text: latest ? _('Install %s').replace('%s', latest) : _('Update'),
        backendAction: 'install_extended_lite',
      });
    } else {
      actions.push({
        loadingKey: 'singBoxExtendedLiteCheck',
        kind: 'check',
        text: _('Check update'),
        backendAction: 'check_update_lite',
      });
    }
  } else {
    actions.push({
      loadingKey: 'singBoxExtendedLiteAction',
      kind: 'switch',
      text: _('Switch to lite'),
      backendAction: 'install_extended_lite',
    });
  }

  return {
    key: 'sing_box_extended_lite',
    title: 'sing-box (extended lite)',
    description: _(
      'Light build of the extended core for low-flash devices (~10 MB instead of ~105 MB)',
    ),
    version: isActive ? systemInfo.sing_box_version : _('Not installed'),
    installed: isActive,
    tag: isActive ? getCheckTag(check.status) : getCheckTag('not_installed'),
    extraTag:
      isActive && upx ? { label: _('UPX'), kind: 'warning' } : undefined,
    note: !supported
      ? _('Not available for your architecture')
      : isActive && upx
        ? _('Compressed build: uses more RAM at startup')
        : undefined,
    actionsDisabled: !supported,
    actions,
  };
}

// The NaiveProxy client (klzgrad/naiveproxy): a separate small program that carries
// naive+https:// links beside sing-box. Installed from the GitHub release.
function naiveCard(
  systemInfo: ManagerSystemInfo,
  check: ManagerCheckState,
): ManagerCardDescriptor {
  const version = systemInfo.naive_version || 'not installed';
  const installed = version !== 'not installed';
  const actions: ManagerActionDescriptor[] = [];

  if (!installed) {
    actions.push({
      loadingKey: 'naiveAction',
      kind: 'naive_install',
      text: _('Install'),
    });
  } else {
    if (check.status === 'outdated') {
      actions.push({
        loadingKey: 'naiveAction',
        kind: 'naive_install',
        text: check.latest_version
          ? _('Install %s').replace('%s', check.latest_version)
          : _('Update'),
      });
    } else {
      actions.push({
        loadingKey: 'naiveCheck',
        kind: 'naive_check',
        text: _('Check update'),
      });
    }

    actions.push({
      loadingKey: 'naiveAction',
      kind: 'naive_remove',
      text: _('Remove'),
    });
  }

  return {
    key: 'naive',
    title: 'NaiveProxy',
    description: _(
      'Client for naive+https:// links (~4 MB), used beside sing-box; not needed with a core that has the naive outbound',
    ),
    version: installed
      ? version === 'unknown'
        ? _('unknown')
        : version
      : _('Not installed'),
    installed,
    tag: installed ? getCheckTag(check.status) : getCheckTag('not_installed'),
    actions,
  };
}

/**
 * Build the Component Manager cards from systemInfo + per-component check
 * state. Pure (no DOM, no store) so it is unit-testable; the controller maps
 * descriptors to DOM + click handlers.
 */
export function getComponentCards(
  systemInfo: ManagerSystemInfo,
  checks: Record<ManagerComponentKey, ManagerCheckState>,
): ManagerCardDescriptor[] {
  return [
    netshiftCard(systemInfo, checks.netshift),
    singBoxStockCard(systemInfo, checks.sing_box_stock),
    singBoxExtendedCard(systemInfo, checks.sing_box_extended),
    singBoxExtendedLiteCard(systemInfo, checks.sing_box_extended_lite),
    naiveCard(systemInfo, checks.naive),
  ];
}
