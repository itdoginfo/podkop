import * as podkopMethods from '../../../methods';
import * as fakeIPMethods from '../../../../fakeip/methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';
import { insertIf } from '../../../../helpers';
import { IDiagnosticsChecksItem } from '../../../../store';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateDiagnosticsCheck({
    order,
    code,
    title,
    description: _('Checking FakeIP, please wait'),
    state: 'loading',
    items: [],
  });

  const routerFakeIPResponse = await podkopMethods.getFakeIPCheck();
  const checkFakeIPResponse = await fakeIPMethods.getFakeIpCheck();
  const checkIPResponse = await fakeIPMethods.getIpCheck();

  console.log('runFakeIPCheck', {
    routerFakeIPResponse,
    checkFakeIPResponse,
    checkIPResponse,
  });

  const checks = {
    router: routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    differentIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  console.log('checks', checks);

  const allGood = checks.router || checks.browserFakeIP || checks.differentIP;
  const atLeastOneGood =
    checks.router && checks.browserFakeIP && checks.differentIP;

  function getMeta(): {
    description: string;
    state: 'loading' | 'warning' | 'success' | 'error' | 'skipped';
  } {
    if (allGood) {
      return {
        state: 'success',
        description: _('FakeIP checks passed'),
      };
    }

    if (atLeastOneGood) {
      return {
        state: 'warning',
        description: _('FakeIP checks partially passed'),
      };
    }

    return {
      state: 'error',
      description: _('FakeIP checks failed'),
    };
  }

  const { state, description } = getMeta();

  updateDiagnosticsCheck({
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
