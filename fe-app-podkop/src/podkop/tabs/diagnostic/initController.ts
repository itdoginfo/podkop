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
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        restart: { loading: false },
      },
    });
    location.reload();
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
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        stop: { loading: false },
      },
    });
    // TODO actualize dashboard
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
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        start: { loading: false },
      },
    });
    location.reload();
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
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        enable: { loading: false },
      },
    });
    //TODO actualize dashboard
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
    store.set({
      diagnosticsActions: {
        ...diagnosticsActions,
        disable: { loading: false },
      },
    });
    //TODO actualize dashboard
  }
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  console.log('renderDiagnosticActionsWidget');

  const container = document.getElementById('pdk_diagnostic-page-actions');

  const renderedActions = renderAvailableActions({
    restart: {
      loading: diagnosticsActions.restart.loading,
      visible: true,
      onClick: handleRestart,
    },
    start: {
      loading: diagnosticsActions.start.loading,
      visible: true,
      onClick: handleStart,
    },
    stop: {
      loading: diagnosticsActions.stop.loading,
      visible: true,
      onClick: handleStop,
    },
    enable: {
      loading: diagnosticsActions.enable.loading,
      visible: true,
      onClick: handleEnable,
    },
    disable: {
      loading: diagnosticsActions.disable.loading,
      visible: true,
      onClick: handleDisable,
    },
    globalCheck: {
      loading: diagnosticsActions.globalCheck.loading,
      visible: true,
      onClick: () => {},
    },
    viewLogs: {
      loading: diagnosticsActions.viewLogs.loading,
      visible: true,
      onClick: () => {},
    },
    showSingBoxConfig: {
      loading: diagnosticsActions.showSingBoxConfig.loading,
      visible: true,
      onClick: () => {},
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

  if (diff.diagnosticsActions) {
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
  });
}
