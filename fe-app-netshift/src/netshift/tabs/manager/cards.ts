import { NetShift } from '../../types';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';

export type ManagerComponentKey =
  | 'netshift'
  | 'sing_box_stock'
  | 'sing_box_extended';

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
  | 'self_update';

export interface ManagerActionDescriptor {
  // The store-slice key driving this button's loading flag.
  loadingKey:
    | 'netshiftCheck'
    | 'netshiftUpdate'
    | 'singBoxStockCheck'
    | 'singBoxStockAction'
    | 'singBoxExtendedCheck'
    | 'singBoxExtendedAction';
  kind: ManagerActionKind;
  text: string;
  // For `update`/`switch`: the backend install action; for `self_update`:
  // 'self_update'; for `check`: the sing-box check action; for `check_netshift`:
  // the NetShift check action (routed to the dedicated NetShift check method).
  backendAction?:
    | 'check_update'
    | 'check_update_stable'
    | 'install_stable'
    | 'install_extended'
    | 'self_update';
}

export interface ManagerCardTag {
  label: string;
  kind: 'neutral' | 'success' | 'warning';
}

export interface ManagerCardDescriptor {
  key: ManagerComponentKey;
  title: string;
  version: string;
  installed: boolean;
  tag?: ManagerCardTag;
  actions: ManagerActionDescriptor[];
}

export type ManagerSystemInfo = {
  netshift_version: string;
  netshift_latest_version: string;
  sing_box_version: string;
  sing_box_extended: 0 | 1;
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
  const isActive = installed && systemInfo.sing_box_extended === 0;
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
  const isActive = installed && systemInfo.sing_box_extended === 1;
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
    version: isActive ? systemInfo.sing_box_version : _('Not installed'),
    installed: isActive,
    tag: isActive ? getCheckTag(check.status) : getCheckTag('not_installed'),
    actions,
  };
}

/**
 * Build the three Component Manager cards from systemInfo + per-component check
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
  ];
}
