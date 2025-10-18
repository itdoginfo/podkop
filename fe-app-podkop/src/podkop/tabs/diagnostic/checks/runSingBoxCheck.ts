import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';

export async function runSingBoxCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.SINGBOX;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking sing-box, please wait'),
    state: 'loading',
    items: [],
  });

  const singBoxChecks = await PodkopShellMethods.checkSingBox();

  if (!singBoxChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
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

  function getStatus() {
    if (allGood) {
      return 'success';
    }

    if (atLeastOneGood) {
      return 'warning';
    }

    return 'error';
  }

  updateCheckStore({
    order,
    code,
    title,
    description: _('Sing-box checks passed'),
    state: getStatus(),
    items: [
      {
        state: data.sing_box_installed ? 'success' : 'error',
        key: _('Sing-box installed'),
        value: '',
      },
      {
        state: data.sing_box_version_ok ? 'success' : 'error',
        key: _('Sing-box version >= 1.12.4'),
        value: '',
      },
      {
        state: data.sing_box_service_exist ? 'success' : 'error',
        key: _('Sing-box service exist'),
        value: '',
      },
      {
        state: data.sing_box_autostart_disabled ? 'success' : 'error',
        key: _('Sing-box autostart disabled'),
        value: '',
      },
      {
        state: data.sing_box_process_running ? 'success' : 'error',
        key: _('Sing-box process running'),
        value: '',
      },
      {
        state: data.sing_box_ports_listening ? 'success' : 'error',
        key: _('Sing-box listening ports'),
        value: '',
      },
    ],
  });

  if (!atLeastOneGood || !data.sing_box_process_running) {
    throw new Error('Sing-box checks failed');
  }
}
