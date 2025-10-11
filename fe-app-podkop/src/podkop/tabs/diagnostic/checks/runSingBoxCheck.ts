import { getSingBoxCheck } from '../../../methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';

export async function runSingBoxCheck() {
  const code = 'sing_box_check';

  updateDiagnosticsCheck({
    code,
    title: _('Sing-box checks'),
    description: _('Checking sing-box, please wait'),
    state: 'loading',
    items: [],
  });

  const singBoxChecks = await getSingBoxCheck();

  if (!singBoxChecks.success) {
    updateDiagnosticsCheck({
      code,
      title: _('Sing-box checks'),
      description: _('Cannot receive Sing-box checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Sing-box checks failed');
  }

  const data = singBoxChecks.data;

  const allGood =
    Boolean(data.sing_box_installed) &&
    Boolean(data.sing_box_version_ok) &&
    Boolean(data.sing_box_service_exist) &&
    Boolean(data.sing_box_autostart_disabled) &&
    Boolean(data.sing_box_process_running) &&
    Boolean(data.sing_box_ports_listening);

  const atLeastOneGood =
    Boolean(data.sing_box_installed) ||
    Boolean(data.sing_box_version_ok) ||
    Boolean(data.sing_box_service_exist) ||
    Boolean(data.sing_box_autostart_disabled) ||
    Boolean(data.sing_box_process_running) ||
    Boolean(data.sing_box_ports_listening);

  console.log('singBoxChecks', singBoxChecks);

  function getStatus() {
    if (allGood) {
      return 'success';
    }

    if (atLeastOneGood) {
      return 'warning';
    }

    return 'error';
  }

  updateDiagnosticsCheck({
    code,
    title: _('Sing-box checks'),
    description: _('Sing-box checks passed'),
    state: getStatus(),
    items: [
      {
        state: data.sing_box_installed ? 'success' : 'error',
        key: _('Sing-box installed'),
        value: data.sing_box_installed ? _('Yes') : _('No'),
      },
      {
        state: data.sing_box_version_ok ? 'success' : 'error',
        key: _('Sing-box version >= 1.12.4'),
        value: data.sing_box_version_ok ? _('Yes') : _('No'),
      },
      {
        state: data.sing_box_service_exist ? 'success' : 'error',
        key: _('Sing-box service exist'),
        value: data.sing_box_service_exist ? _('Yes') : _('No'),
      },
      {
        state: data.sing_box_autostart_disabled ? 'success' : 'error',
        key: _('Sing-box autostart disabled'),
        value: data.sing_box_autostart_disabled ? _('Yes') : _('No'),
      },
      {
        state: data.sing_box_process_running ? 'success' : 'error',
        key: _('Sing-box process running'),
        value: data.sing_box_process_running ? _('Yes') : _('No'),
      },
      {
        state: data.sing_box_ports_listening ? 'success' : 'error',
        key: _('Sing-box listening ports'),
        value: data.sing_box_ports_listening ? _('Yes') : _('No'),
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('Sing-box checks failed');
  }
}
