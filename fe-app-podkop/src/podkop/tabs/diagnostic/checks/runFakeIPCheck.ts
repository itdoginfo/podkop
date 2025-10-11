import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';

export async function runFakeIPCheck() {
  const code = 'fake_ip_check';

  updateDiagnosticsCheck({
    code,
    title: _('Fake IP checks'),
    description: _('Not implemented yet'),
    state: 'skipped',
    items: [],
  });
}
