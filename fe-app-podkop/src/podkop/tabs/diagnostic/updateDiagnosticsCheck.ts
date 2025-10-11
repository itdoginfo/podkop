import { IDiagnosticsChecksStoreItem, store } from '../../../store';

export function updateDiagnosticsCheck(check: IDiagnosticsChecksStoreItem) {
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const other = diagnosticsChecks.filter((item) => item.code !== check.code);

  store.set({
    diagnosticsChecks: [...other, check],
  });
}
