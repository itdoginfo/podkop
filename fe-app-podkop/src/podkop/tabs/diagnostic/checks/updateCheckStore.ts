import { IDiagnosticsChecksStoreItem, store } from '../../../services';

export function updateCheckStore(
  check: IDiagnosticsChecksStoreItem,
  minified?: boolean,
) {
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const other = diagnosticsChecks.filter((item) => item.code !== check.code);

  const smallCheck: IDiagnosticsChecksStoreItem = {
    ...check,
    items: check.items.filter((item) => item.state !== 'success'),
  };

  const targetCheck = minified ? smallCheck : check;

  store.set({
    diagnosticsChecks: [...other, targetCheck],
  });
}
