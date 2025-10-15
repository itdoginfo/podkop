import { onMount, preserveScrollForPage } from '../../../helpers';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runNftCheck } from './checks/runNftCheck';
import { runFakeIPCheck } from './checks/runFakeIPCheck';
import { loadingDiagnosticsChecksStore } from './diagnostic.store';
import { store, StoreType } from '../../services';
import {
  renderAvailableActions,
  renderCheckSection,
  renderRunAction,
  renderSystemInfo,
} from './partials';
import { PodkopShellMethods } from '../../methods';
import { fetchServicesInfo } from '../../fetchers';

function renderDiagnosticsChecks() {
  console.log('renderDiagnosticsChecks');
  const diagnosticsChecks = store
    .get()
    .diagnosticsChecks.sort((a, b) => a.order - b.order);
  const container = document.getElementById('pdk_diagnostic-page-checks');

  const renderedDiagnosticsChecks = diagnosticsChecks.map((check) =>
    renderCheckSection(check),
  );

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedDiagnosticsChecks);
  });
}

function renderDiagnosticRunActionWidget() {
  console.log('renderDiagnosticRunActionWidget');

  const { loading } = store.get().diagnosticsRunAction;
  const container = document.getElementById('pdk_diagnostic-page-run-check');

  const renderedAction = renderRunAction({
    loading,
    click: () => runChecks(),
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
  });
}

async function handleRestart() {
  const diagnosticsActions = store.get().diagnosticsActions;
  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      restart: { loading: true },
    },
  });

  try {
    await PodkopShellMethods.restart();
  } catch (e) {
    console.log('handleRestart - e', e);
  } finally {
    setTimeout(async () => {
      await fetchServicesInfo();
      store.set({
        diagnosticsActions: {
          ...diagnosticsActions,
          restart: { loading: false },
        },
      });
    }, 5000);
  }
}

async function handleStop() {
  const diagnosticsActions = store.get().diagnosticsActions;
  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      stop: { loading: true },
    },
  });

  try {
    await PodkopShellMethods.stop();
  } catch (e) {
    console.log('handleStop - e', e);
  } finally {
    await fetchServicesInfo();
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        stop: { loading: false },
      },
    });
  }
}

async function handleStart() {
  const diagnosticsActions = store.get().diagnosticsActions;
  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      start: { loading: true },
    },
  });

  try {
    await PodkopShellMethods.start();
  } catch (e) {
    console.log('handleStart - e', e);
  } finally {
    setTimeout(async () => {
      await fetchServicesInfo();
      store.set({
        diagnosticsActions: {
          ...diagnosticsActions,
          start: { loading: false },
        },
      });
    }, 5000);
  }
}

async function handleEnable() {
  const diagnosticsActions = store.get().diagnosticsActions;
  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      enable: { loading: true },
    },
  });

  try {
    await PodkopShellMethods.enable();
  } catch (e) {
    console.log('handleEnable - e', e);
  } finally {
    await fetchServicesInfo();
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        enable: { loading: false },
      },
    });
  }
}

async function handleDisable() {
  const diagnosticsActions = store.get().diagnosticsActions;
  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      disable: { loading: true },
    },
  });

  try {
    await PodkopShellMethods.disable();
  } catch (e) {
    console.log('handleDisable - e', e);
  } finally {
    await fetchServicesInfo();
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        disable: { loading: false },
      },
    });
  }
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  const servicesInfoWidget = store.get().servicesInfoWidget;
  console.log('renderDiagnosticActionsWidget');

  const podkopEnabled = Boolean(servicesInfoWidget.data.podkop);
  const singBoxRunning = Boolean(servicesInfoWidget.data.singbox);
  const atLeastOneServiceCommandLoading =
    servicesInfoWidget.loading ||
    diagnosticsActions.restart.loading ||
    diagnosticsActions.start.loading ||
    diagnosticsActions.stop.loading;

  const container = document.getElementById('pdk_diagnostic-page-actions');

  const renderedActions = renderAvailableActions({
    restart: {
      loading: diagnosticsActions.restart.loading,
      visible: true,
      onClick: handleRestart,
      disabled: atLeastOneServiceCommandLoading,
    },
    start: {
      loading: diagnosticsActions.start.loading,
      visible: !singBoxRunning,
      onClick: handleStart,
      disabled: atLeastOneServiceCommandLoading,
    },
    stop: {
      loading: diagnosticsActions.stop.loading,
      visible: singBoxRunning,
      onClick: handleStop,
      disabled: atLeastOneServiceCommandLoading,
    },
    enable: {
      loading: diagnosticsActions.enable.loading,
      visible: !podkopEnabled,
      onClick: handleEnable,
      disabled: atLeastOneServiceCommandLoading,
    },
    disable: {
      loading: diagnosticsActions.disable.loading,
      visible: podkopEnabled,
      onClick: handleDisable,
      disabled: atLeastOneServiceCommandLoading,
    },
    globalCheck: {
      loading: diagnosticsActions.globalCheck.loading,
      visible: true,
      onClick: () => {},
      disabled: atLeastOneServiceCommandLoading,
    },
    viewLogs: {
      loading: diagnosticsActions.viewLogs.loading,
      visible: true,
      onClick: () => {},
      disabled: atLeastOneServiceCommandLoading,
    },
    showSingBoxConfig: {
      loading: diagnosticsActions.showSingBoxConfig.loading,
      visible: true,
      onClick: () => {},
      disabled: atLeastOneServiceCommandLoading,
    },
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedActions);
  });
}

function renderDiagnosticSystemInfoWidget() {
  console.log('renderDiagnosticSystemInfoWidget');

  const container = document.getElementById('pdk_diagnostic-page-system-info');

  const renderedSystemInfo = renderSystemInfo({
    items: [
      {
        key: 'Podkop',
        value: '1',
      },
      {
        key: 'Luci App',
        value: '1',
      },
      {
        key: 'Sing-box',
        value: '1',
      },
      {
        key: 'OS',
        value: '1',
      },
      {
        key: 'Device',
        value: '1',
      },
    ],
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedSystemInfo);
  });
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsChecks) {
    renderDiagnosticsChecks();
  }

  if (diff.diagnosticsRunAction) {
    renderDiagnosticRunActionWidget();
  }

  if (diff.diagnosticsActions || diff.servicesInfoWidget) {
    renderDiagnosticAvailableActionsWidget();
  }
}

async function runChecks() {
  try {
    store.set({
      diagnosticsRunAction: { loading: true },
      diagnosticsChecks: loadingDiagnosticsChecksStore.diagnosticsChecks,
    });

    await runDnsCheck();

    await runSingBoxCheck();

    await runNftCheck();

    await runFakeIPCheck();
  } catch (e) {
    console.log('runChecks - e', e);
  } finally {
    store.set({ diagnosticsRunAction: { loading: false } });
  }
}

export async function initController(): Promise<void> {
  onMount('diagnostic-status').then(() => {
    console.log('diagnostic controller initialized.');
    // Remove old listener
    store.unsubscribe(onStoreUpdate);

    // Add new listener
    store.subscribe(onStoreUpdate);

    // Initial checks render
    renderDiagnosticsChecks();

    // Initial run checks action render
    renderDiagnosticRunActionWidget();

    // Initial available actions render
    renderDiagnosticAvailableActionsWidget();

    // Initial system info render
    renderDiagnosticSystemInfoWidget();

    // Initial services info fetch
    fetchServicesInfo();
  });
}
