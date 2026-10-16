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
  ManagerCardTag,
  ManagerComponentKey,
  getComponentCards,
  getSingBoxMutationWarningMessage,
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
        sing_box_variant: systemInfo.data.sing_box_variant,
        sing_box_lite_upx: systemInfo.data.sing_box_lite_upx === 1 ? 1 : 0,
        sing_box_lite_supported:
          systemInfo.data.sing_box_lite_supported === 1 ? 1 : 0,
        naive_version: systemInfo.data.naive_version || 'not installed',
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
        sing_box_variant: 'stock',
        sing_box_lite_upx: 0,
        sing_box_lite_supported: 0,
        naive_version: 'not installed',
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
    // Route the card's backendAction to the sync check call — the extended
    // lite card checks its own repo via check_update_lite.
    const checkAction =
      button.backendAction === 'check_update_stable' ||
      button.backendAction === 'check_update_lite'
        ? button.backendAction
        : 'check_update';

    const parsed = await NetShiftShellMethods.singBoxCheckUpdate(checkAction);

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
    // Route the card's backendAction to the async install call — the extended
    // lite card switches through install_extended_lite.
    const installAction =
      button.backendAction === 'install_stable' ||
      button.backendAction === 'install_extended_lite'
        ? button.backendAction
        : 'install_extended';

    const result =
      await NetShiftShellMethods.singBoxComponentAction(installAction);

    if (result.success) {
      const changed = _('Sing-box core changed, version:');

      showToast(`${changed} ${result.version || ''}`.trim(), 'success');
      resetCheckResult(component);
      await fetchSystemInfo();
    } else {
      logger.error('[MANAGER]', 'runSingBoxMutation failed', result);
      showToast(result.message || _('Failed to execute!'), 'error');
    }

    // Reported separately from the outcome: a core that did switch can still
    // leave the package manager in a state that blocks later upgrades, and the
    // lite installer can flag the UPX RAM spike — machine codes map to
    // translatable strings, backend prose passes through.
    if (result.warning) {
      logger.warn('[MANAGER]', 'runSingBoxMutation warning', result.warning);
      showToast(
        getSingBoxMutationWarningMessage(result.warning),
        'warning',
        15000,
      );
    }
  } catch (error) {
    logger.error('[MANAGER]', 'runSingBoxMutation failed', error);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setActionLoading(button.loadingKey, false);
  }
}

// NaiveProxy client: check, install/update, remove.
async function runNaiveCheck(button: ManagerActionDescriptor) {
  setActionLoading(button.loadingKey, true);

  try {
    const parsed = await NetShiftShellMethods.naiveCheckUpdate();

    if (!parsed.success) {
      showToast(parsed.message || _('Failed to execute!'), 'error');
      return;
    }

    const status = parsed.status ?? null;

    setCheckResult('naive', status, parsed.latest_version || '');
    showToast(getCheckToastMessage(status), 'success');
  } catch (error) {
    logger.error('[MANAGER]', 'runNaiveCheck failed', error);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setActionLoading(button.loadingKey, false);
  }
}

async function runNaiveAction(
  button: ManagerActionDescriptor,
  action: 'install' | 'remove',
) {
  setActionLoading(button.loadingKey, true);
  showToast(
    action === 'install'
      ? _('Installing the NaiveProxy client, this may take a minute…')
      : _('Removing the NaiveProxy client…'),
    'info',
  );

  try {
    const result = await NetShiftShellMethods.naiveComponentAction(action);

    if (result.success) {
      showToast(
        action === 'install'
          ? `${_('NaiveProxy client installed, version:')} ${result.version || ''}`.trim()
          : _('NaiveProxy client removed'),
        'success',
      );
      resetCheckResult('naive');
      await fetchSystemInfo();
    } else {
      logger.error('[MANAGER]', 'runNaiveAction failed', result);
      showToast(result.message || _('Failed to execute!'), 'error');
    }
  } catch (error) {
    logger.error('[MANAGER]', 'runNaiveAction failed', error);
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

  if (button.kind === 'naive_check') {
    void runNaiveCheck(button);
    return;
  }

  if (button.kind === 'naive_install') {
    void runNaiveAction(button, 'install');
    return;
  }

  if (button.kind === 'naive_remove') {
    void runNaiveAction(button, 'remove');
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

function renderComponentTag(tag: ManagerCardTag) {
  return E(
    'span',
    {
      class: [
        'pdk_manager-page__component__tag',
        tag.kind === 'success'
          ? 'pdk_manager-page__component__tag--success'
          : '',
        tag.kind === 'warning'
          ? 'pdk_manager-page__component__tag--warning'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    tag.label,
  );
}

function renderComponentCard(card: ManagerCardDescriptor) {
  const managerActions = store.get().managerActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();
  const tags = [card.tag, card.extraTag].filter((tag): tag is ManagerCardTag =>
    Boolean(tag),
  );
  const headerChildren: Node[] = [
    E('b', { class: 'pdk_manager-page__component__title' }, card.title),
  ];

  if (tags.length > 0) {
    headerChildren.push(
      E('div', { class: 'pdk_manager-page__component__status' }, [
        ...tags.map(renderComponentTag),
      ]),
    );
  }

  const children: Node[] = [
    E('div', { class: 'pdk_manager-page__component__header' }, headerChildren),
  ];

  if (card.description) {
    children.push(
      E(
        'div',
        { class: 'pdk_manager-page__component__description' },
        card.description,
      ),
    );
  }

  children.push(
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
            action.kind === 'check' ||
            action.kind === 'check_netshift' ||
            action.kind === 'naive_check'
              ? renderSearchIcon24
              : renderRotateCcwIcon24,
          loading,
          disabled:
            systemInfoLoading ||
            card.actionsDisabled ||
            (anyActionLoading && !loading),
          onClick: () => handleManagerAction(card, action),
        });
      }),
    ),
  );

  if (card.note) {
    children.push(
      E('div', { class: 'pdk_manager-page__component__note' }, card.note),
    );
  }

  return E('div', { class: 'card pdk_manager-page__component' }, children);
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
      sing_box_variant: diagnosticsSystemInfo.sing_box_variant,
      sing_box_lite_upx: diagnosticsSystemInfo.sing_box_lite_upx,
      sing_box_lite_supported: diagnosticsSystemInfo.sing_box_lite_supported,
      naive_version: diagnosticsSystemInfo.naive_version,
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
