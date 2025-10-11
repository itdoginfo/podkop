import { getNftRulesCheck } from '../../../methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';

export async function runNftCheck() {
  const code = 'nft_check';

  updateDiagnosticsCheck({
    code,
    title: _('Nftables checks'),
    description: _('Checking nftables, please wait'),
    state: 'loading',
    items: [],
  });

  const nftablesChecks = await getNftRulesCheck();

  if (!nftablesChecks.success) {
    updateDiagnosticsCheck({
      code,
      title: _('Nftables checks'),
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
    Boolean(data.rules_other_mark_exist);

  const atLeastOneGood =
    Boolean(data.table_exist) ||
    Boolean(data.rules_mangle_exist) ||
    Boolean(data.rules_mangle_counters) ||
    Boolean(data.rules_mangle_output_exist) ||
    Boolean(data.rules_mangle_output_counters) ||
    Boolean(data.rules_proxy_exist) ||
    Boolean(data.rules_proxy_counters) ||
    Boolean(data.rules_other_mark_exist);

  console.log('nftablesChecks', nftablesChecks);

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
    title: _('Nftables checks'),
    description: allGood
      ? _('Nftables checks passed')
      : _('Nftables checks partially passed'),
    state: getStatus(),
    items: [
      {
        state: data.table_exist ? 'success' : 'error',
        key: _('Table exist'),
        value: data.table_exist ? _('Yes') : _('No'),
      },
      {
        state: data.rules_mangle_exist ? 'success' : 'error',
        key: _('Rules mangle exist'),
        value: data.rules_mangle_exist ? _('Yes') : _('No'),
      },
      {
        state: data.rules_mangle_counters ? 'success' : 'error',
        key: _('Rules mangle counters'),
        value: data.rules_mangle_counters ? _('Yes') : _('No'),
      },
      {
        state: data.rules_mangle_output_exist ? 'success' : 'error',
        key: _('Rules mangle output exist'),
        value: data.rules_mangle_output_exist ? _('Yes') : _('No'),
      },
      {
        state: data.rules_mangle_output_counters ? 'success' : 'error',
        key: _('Rules mangle output counters'),
        value: data.rules_mangle_output_counters ? _('Yes') : _('No'),
      },
      {
        state: data.rules_proxy_exist ? 'success' : 'error',
        key: _('Rules proxy exist'),
        value: data.rules_proxy_exist ? _('Yes') : _('No'),
      },
      {
        state: data.rules_proxy_counters ? 'success' : 'error',
        key: _('Rules proxy counters'),
        value: data.rules_proxy_counters ? _('Yes') : _('No'),
      },
      {
        state: data.rules_other_mark_exist ? 'warning' : 'success',
        key: _('Rules other mark exist'),
        value: data.rules_other_mark_exist ? _('Yes') : _('No'),
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('Nftables checks failed');
  }
}
