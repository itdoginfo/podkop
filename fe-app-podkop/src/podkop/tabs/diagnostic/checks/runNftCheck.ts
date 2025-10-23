import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { RemoteFakeIPMethods, PodkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';

export async function runNftCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.NFT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking nftables, please wait'),
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
      description: _('Cannot receive nftables checks result'),
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
    description: allGood
      ? _('Nftables checks passed')
      : _('Nftables checks partially passed'),
    state: getStatus(),
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
