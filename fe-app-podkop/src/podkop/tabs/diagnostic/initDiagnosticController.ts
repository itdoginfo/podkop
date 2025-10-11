import { onMount, preserveScrollForPage } from '../../../helpers';
import { store, StoreType } from '../../../store';
import { renderCheckSection } from './renderCheckSection';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runNftCheck } from './checks/runNftCheck';

async function renderDiagnosticsChecks() {
  console.log('renderDiagnosticsChecks');
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const container = document.getElementById('pdk_diagnostic-page-checks');

  const renderedDiagnosticsChecks = diagnosticsChecks.map((check) =>
    renderCheckSection(check),
  );

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedDiagnosticsChecks);
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
}

async function runChecks() {
  await runDnsCheck();

  await runSingBoxCheck();

  await runNftCheck();
}

export async function initDiagnosticController(): Promise<void> {
  onMount('diagnostic-status').then(() => {
    console.log('diagnostic controller initialized.');
    // Remove old listener
    store.unsubscribe(onStoreUpdate);

    // Clear store
    store.reset();

    // Add new listener
    store.subscribe(onStoreUpdate);

    // TMP run checks on mount
    runChecks();
  });
}
