import { onMount, preserveScrollForPage } from '../../../helpers';
import { renderCheckSection } from './renderCheckSection';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runNftCheck } from './checks/runNftCheck';
import { runFakeIPCheck } from './checks/runFakeIPCheck';
import { renderDiagnosticRunAction } from './renderDiagnosticRunAction';
import { renderAvailableActions } from './renderAvailableActions';
import { renderSystemInfo } from './renderSystemInfo';
import { loadingDiagnosticsChecksStore } from './diagnostic.store';
import { store, StoreType } from '../../services';

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

  const renderedAction = renderDiagnosticRunAction({
    loading,
    click: () => runChecks(),
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
  });
}

function renderDiagnosticAvailableActionsWidget() {
  console.log('renderDiagnosticActionsWidget');

  const container = document.getElementById('pdk_diagnostic-page-actions');

  const renderedActions = renderAvailableActions();

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

export async function initDiagnosticController(): Promise<void> {
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
