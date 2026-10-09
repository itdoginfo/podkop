import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { NetShiftShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getEnvironmentItems } from '../helpers/getEnvironmentItems';

export async function runEnvironmentCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.ENVIRONMENT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const response = await NetShiftShellMethods.checkEnvironment();

  // An older backend has no such command: the hints are optional, so this is
  // not an error of the router.
  if (
    !response.success ||
    typeof response.data !== 'object' ||
    response.data === null
  ) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Not available'),
      state: 'skipped',
      items: [],
    });

    return;
  }

  const items = getEnvironmentItems(response.data);
  const hasError = items.some((item) => item.state === 'error');
  const hasWarning = items.some((item) => item.state === 'warning');

  updateCheckStore({
    order,
    code,
    title,
    description: hasError
      ? _('Checks failed')
      : hasWarning
        ? _('Issues detected')
        : _('Checks passed'),
    state: hasError ? 'error' : hasWarning ? 'warning' : 'success',
    items,
  });
}
