import { onMount, preserveScrollForPage } from '../../../helpers';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import { renderRotateCcwIcon24, renderSearchIcon24 } from '../../../icons';
import { renderButton } from '../../../partials';
import { NetShiftShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { NetShift } from '../../types';
import {
  ManagerActionDescriptor,
  ManagerCardDescriptor,
  ManagerComponentKey,
  getComponentCards,
} from './cards';

type ManagerActionKey = keyof StoreType['managerActions'];

let managerLifecycleRegistered = false;
let managerControllerInitialized = false;
let managerMounted = false;

async function fetchSystemInfo() {
  const systemInfo = await NetShiftShellMethods.getSystemInfo();

  if (systemInfo.success) {
    store.set({
      diagnosticsSystemInfo: {
        loading: false,
        ...systemInfo.data,
        sing_box_extended: systemInfo.data.sing_box_extended === 1 ? 1 : 0,
      },
    });
  } else {
    store.set({
      diagnosticsSystemInfo: {
        loading: false,
        netshift_version: _('unknown'),
        netshift_latest_version: _('unknown'),
        luci_app_version: _('unknown'),
        sing_box_version: _('unknown'),
        openwrt_version: _('unknown'),
        device_model: _('unknown'),
        sing_box_extended: 0,
      },
    });
  }
}

function isAnyActionLoading() {
  return Object.values(store.get().managerActions).some((item) => item.loading);
}

function isSystemInfoLoading() {
  return store.get().diagnosticsSystemInfo.loading;
}

function setActionLoading(action: ManagerActionKey, loading: boolean) {
  const managerActions = store.get().managerActions;

  store.set({
    managerActions: {
      ...managerActions,
      [action]: { loading },
    },
  });
}

function setCheckResult(
  component: ManagerComponentKey,
  status: NetShift.ComponentUpdateStatus | null,
  latestVersion: string,
) {
  const managerChecks = store.get().managerChecks;

  store.set({
    managerChecks: {
      ...managerChecks,
      [component]: {
        status,
        latest_version: latestVersion,
      },
    },
  });
}

function resetCheckResult(component: ManagerComponentKey) {
  setCheckResult(component, null, '');
}

function getCheckToastMessage(status: NetShift.ComponentUpdateStatus | null) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  if (status === 'not_installed') {
    return _('Not installed');
  }

  return _('Latest version is installed');
}

// Sing-box check: routes to the sing-box check method (stock or extended) and
// stores the result into the matching managerChecks slice.
async function runSingBoxCheck(
  component: ManagerComponentKey,
  button: ManagerActionDescriptor,
) {
  setActionLoading(button.loadingKey, true);

  try {
    const parsed = await NetShiftShellMethods.singBoxCheckUpdate(
      button.backendAction === 'check_update_stable'
        ? 'check_update_stable'
        : 'check_update',
    );

    if (!parsed.success) {
      showToast(parsed.message || _('Failed to execute!'), 'error');
      return;
    }

    const status = parsed.status ?? null;

    setCheckResult(component, status, parsed.latest_version || '');
    showToast(getCheckToastMessage(status), 'success');
  } catch (error) {
    logger.error('[MANAGER]', 'runSingBoxCheck failed', error);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setActionLoading(button.loadingKey, false);
  }
}

// NetShift check (task-030): on-demand call to the dedicated
// `component_action netshift check_update` action, which returns the same
// {success, current_version, latest_version, status} contract as the sing-box
// cores (status already v-normalized server-side). We TRUST result.status and
// write it into managerChecks.netshift — mirroring runSingBoxCheck precisely.
async function runNetshiftCheck(button: ManagerActionDescriptor) {
  setActionLoading(button.loadingKey, true);

  try {
    const parsed = await NetShiftShellMethods.netshiftCheckUpdate();

    if (!parsed.success) {
      showToast(parsed.message || _('Failed to execute!'), 'error');
      return;
    }

    const status = parsed.status ?? null;

    setCheckResult('netshift', status, parsed.latest_version || '');
    showToast(getCheckToastMessage(status), 'success');
  } catch (error) {
    logger.error('[MANAGER]', 'runNetshiftCheck failed', error);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setActionLoading(button.loadingKey, false);
  }
}

async function runSingBoxMutation(
  component: ManagerComponentKey,
  button: ManagerActionDescriptor,
) {
  setActionLoading(button.loadingKey, true);
  showToast(_('Switching sing-box core, this may take a few minutes…'), 'info');

  try {
    const result = await NetShiftShellMethods.singBoxComponentAction(
      button.backendAction === 'install_stable'
        ? 'install_stable'
        : 'install_extended',
    );

    if (result.success) {
      const changed = _('Sing-box core changed, version:');

      showToast(`${changed} ${result.version || ''}`.trim(), 'success');
      resetCheckResult(component);
      await fetchSystemInfo();
    } else {
      logger.error('[MANAGER]', 'runSingBoxMutation failed', result);
      showToast(result.message || _('Failed to execute!'), 'error');
    }
  } catch (error) {
    logger.error('[MANAGER]', 'runSingBoxMutation failed', error);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setActionLoading(button.loadingKey, false);
  }
}

function reloadPageAfterSelfUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

async function runNetshiftSelfUpdate(button: ManagerActionDescriptor) {
  setActionLoading(button.loadingKey, true);
  // Warning-style toast: self-update is long and ends in a page reload.
  showToast(
    _('Updating NetShift, this may take a few minutes; the page will reload…'),
    'warning',
    6000,
  );

  try {
    const result = await NetShiftShellMethods.netshiftSelfUpdate();

    if (result.success) {
      const updated = _('NetShift updated, version:');

      showToast(`${updated} ${result.version || ''}`.trim(), 'success', 1200);
      reloadPageAfterSelfUpdate();
      return;
    }

    logger.error('[MANAGER]', 'runNetshiftSelfUpdate failed', result);
    showToast(result.message || _('Failed to execute!'), 'error');
    setActionLoading(button.loadingKey, false);
  } catch (error) {
    logger.error('[MANAGER]', 'runNetshiftSelfUpdate failed', error);
    showToast(_('Failed to execute!'), 'error');
    setActionLoading(button.loadingKey, false);
  }
}

function handleManagerAction(
  card: ManagerCardDescriptor,
  button: ManagerActionDescriptor,
) {
  if (isAnyActionLoading()) {
    return;
  }

  if (button.kind === 'check_netshift') {
    void runNetshiftCheck(button);
    return;
  }

  if (button.kind === 'check') {
    void runSingBoxCheck(card.key, button);
    return;
  }

  if (button.kind === 'self_update') {
    void runNetshiftSelfUpdate(button);
    return;
  }

  // `update` / `switch` — both drive the async sing-box install contract.
  void runSingBoxMutation(card.key, button);
}

function renderComponentTag(card: ManagerCardDescriptor) {
  if (!card.tag) {
    return null;
  }

  return E(
    'span',
    {
      class: [
        'pdk_manager-page__component__tag',
        card.tag.kind === 'success'
          ? 'pdk_manager-page__component__tag--success'
          : '',
        card.tag.kind === 'warning'
          ? 'pdk_manager-page__component__tag--warning'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    card.tag.label,
  );
}

function renderComponentCard(card: ManagerCardDescriptor) {
  const managerActions = store.get().managerActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();
  const tag = renderComponentTag(card);
  const headerChildren: Node[] = [
    E('b', { class: 'pdk_manager-page__component__title' }, card.title),
  ];

  if (tag) {
    headerChildren.push(
      E('div', { class: 'pdk_manager-page__component__status' }, [tag]),
    );
  }

  return E('div', { class: 'card pdk_manager-page__component' }, [
    E('div', { class: 'pdk_manager-page__component__header' }, headerChildren),
    E('div', { class: 'pdk_manager-page__component__version' }, [
      E(
        'span',
        { class: 'pdk_manager-page__component__version__label' },
        _('Version'),
      ),
      E(
        'span',
        { class: 'pdk_manager-page__component__version__value' },
        card.version,
      ),
    ]),
    E(
      'div',
      { class: 'pdk_manager-page__component__actions' },
      card.actions.map((action) => {
        const loading = managerActions[action.loadingKey].loading;

        return renderButton({
          text: action.text,
          icon:
            action.kind === 'check' || action.kind === 'check_netshift'
              ? renderSearchIcon24
              : renderRotateCcwIcon24,
          loading,
          disabled: systemInfoLoading || (anyActionLoading && !loading),
          onClick: () => handleManagerAction(card, action),
        });
      }),
    ),
  ]);
}

function renderManagerComponents() {
  const container = document.getElementById('pdk_manager-components');

  if (!container) {
    return;
  }

  const { diagnosticsSystemInfo, managerChecks } = store.get();
  const renderedComponents = getComponentCards(
    {
      netshift_version: normalizeCompiledVersion(
        diagnosticsSystemInfo.netshift_version,
      ),
      netshift_latest_version: diagnosticsSystemInfo.netshift_latest_version,
      sing_box_version: diagnosticsSystemInfo.sing_box_version,
      sing_box_extended: diagnosticsSystemInfo.sing_box_extended,
    },
    managerChecks,
  ).map(renderComponentCard);

  return preserveScrollForPage(() => {
    container.replaceChildren(...renderedComponents);
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsSystemInfo || diff.managerActions || diff.managerChecks) {
    renderManagerComponents();
  }
}

function onPageMount() {
  onPageUnmount();

  managerMounted = true;
  store.subscribe(onStoreUpdate);
  renderManagerComponents();
  void fetchSystemInfo();
}

function onPageUnmount() {
  managerMounted = false;
  store.unsubscribe(onStoreUpdate);
  store.reset(['managerActions', 'managerChecks']);
}

function registerLifecycleListeners() {
  if (managerLifecycleRegistered) {
    return;
  }

  managerLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isManagerVisible = next.tabService.current === 'manager';

      if (isManagerVisible) {
        return onPageMount();
      }

      if (managerMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (managerControllerInitialized) {
    return;
  }

  managerControllerInitialized = true;

  onMount('manager-status').then(() => {
    logger.debug('[MANAGER]', 'initController', 'onMount');
    registerLifecycleListeners();

    if (store.get().tabService.current === 'manager') {
      onPageMount();
    }
  });
}
