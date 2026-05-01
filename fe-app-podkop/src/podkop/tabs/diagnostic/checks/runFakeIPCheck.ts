import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import {
  CustomPodkopMethods,
  PodkopShellMethods,
  RemoteFakeIPMethods,
} from '../../../methods';
import { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  let fakeIpDisabled = false;
  try {
    fakeIpDisabled = await CustomPodkopMethods.getDisableFakeip();
  } catch {
    // If reading UCI fails for any reason, fall back to running the regular FakeIP check
    // instead of crashing the whole diagnostic pipeline.
    fakeIpDisabled = false;
  }
  if (fakeIpDisabled) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('FakeIP is intentionally disabled in Additional Settings'),
      state: 'skipped',
      items: [
        {
          state: 'success',
          key: _('FakeIP disabled'),
          value: '',
        },
      ],
    });
    return;
  }

  const routerFakeIPResponse = await PodkopShellMethods.checkFakeIP();
  const checkFakeIPResponse = await RemoteFakeIPMethods.getFakeIpCheck();
  const checkIPResponse = await RemoteFakeIPMethods.getIpCheck();

  const checks = {
    router: routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    differentIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  const allGood = checks.router || checks.browserFakeIP || checks.differentIP;
  const atLeastOneGood =
    checks.router && checks.browserFakeIP && checks.differentIP;

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.router ? 'success' : 'warning',
        key: checks.router
          ? _('Router DNS is routed through sing-box')
          : _('Router DNS is not routed through sing-box'),
        value: '',
      },
      {
        state: checks.browserFakeIP ? 'success' : 'error',
        key: checks.browserFakeIP
          ? _('Browser is using FakeIP correctly')
          : _('Browser is not using FakeIP'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(checks.browserFakeIP, [
        {
          state: checks.differentIP ? 'success' : 'error',
          key: checks.differentIP
            ? _('Proxy traffic is routed via FakeIP')
            : _('Proxy traffic is not routed via FakeIP'),
          value: '',
        },
      ]),
    ],
  });
}
