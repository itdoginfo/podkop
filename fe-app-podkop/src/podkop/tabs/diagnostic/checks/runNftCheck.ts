import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { RemoteFakeIPMethods, PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runNftCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.NFT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  await RemoteFakeIPMethods.getFakeIpCheck();
  await RemoteFakeIPMethods.getIpCheck();

  const nftablesChecks = await PodkopShellMethods.checkNftRules();

  if (!nftablesChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Nftables checks failed');
  }

  const data = nftablesChecks.data;

  const allGood =
    Boolean(data.table_exist) &&
    Boolean(data.rules_mangle_exist) &&
    Boolean(data.rules_mangle_counters) &&
    Boolean(data.rules_mangle_output_exist) &&
    Boolean(data.rules_mangle_output_counters) &&
    Boolean(data.rules_proxy_exist) &&
    Boolean(data.rules_proxy_counters) &&
    !data.rules_other_mark_exist;

  const atLeastOneGood =
    Boolean(data.table_exist) ||
    Boolean(data.rules_mangle_exist) ||
    Boolean(data.rules_mangle_counters) ||
    Boolean(data.rules_mangle_output_exist) ||
    Boolean(data.rules_mangle_output_counters) ||
    Boolean(data.rules_proxy_exist) ||
    Boolean(data.rules_proxy_counters) ||
    !data.rules_other_mark_exist;

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: data.table_exist ? 'success' : 'error',
        key: _('Table exist'),
        value: '',
      },
      {
        state: data.rules_mangle_exist ? 'success' : 'error',
        key: _('Rules mangle exist'),
        value: '',
      },
      {
        state: data.rules_mangle_counters ? 'success' : 'error',
        key: _('Rules mangle counters'),
        value: '',
      },
      {
        state: data.rules_mangle_output_exist ? 'success' : 'error',
        key: _('Rules mangle output exist'),
        value: '',
      },
      {
        state: data.rules_mangle_output_counters ? 'success' : 'error',
        key: _('Rules mangle output counters'),
        value: '',
      },
      {
        state: data.rules_proxy_exist ? 'success' : 'error',
        key: _('Rules proxy exist'),
        value: '',
      },
      {
        state: data.rules_proxy_counters ? 'success' : 'error',
        key: _('Rules proxy counters'),
        value: '',
      },
      {
        state: !data.rules_other_mark_exist ? 'success' : 'warning',
        key: !data.rules_other_mark_exist
          ? _('No other marking rules found')
          : _('Additional marking rules found'),
        value: '',
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('Nftables checks failed');
  }
}
