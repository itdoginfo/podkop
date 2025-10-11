import { getDNSCheck } from '../../../methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';

export async function runDnsCheck() {
  const code = 'dns_check';

  updateDiagnosticsCheck({
    code,
    title: _('DNS checks'),
    description: _('Checking dns, please wait'),
    state: 'loading',
    items: [],
  });

  const dnsChecks = await getDNSCheck();

  if (!dnsChecks.success) {
    updateDiagnosticsCheck({
      code,
      title: _('DNS checks'),
      description: _('Cannot receive DNS checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('DNS checks failed');
  }

  const data = dnsChecks.data;

  const allGood =
    Boolean(data.local_dns_status) &&
    Boolean(data.bootstrap_dns_status) &&
    Boolean(data.dns_status);

  const atLeastOneGood =
    Boolean(data.local_dns_status) ||
    Boolean(data.bootstrap_dns_status) ||
    Boolean(data.dns_status);

  console.log('dnsChecks', dnsChecks);

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
    title: _('DNS checks'),
    description: _('DNS checks passed'),
    state: getStatus(),
    items: [
      {
        state: data.bootstrap_dns_status ? 'success' : 'error',
        key: _('Bootsrap DNS'),
        value: data.bootstrap_dns_server,
      },
      {
        state: data.dns_status ? 'success' : 'error',
        key: _('Main DNS'),
        value: `${data.dns_server} [${data.dns_type}]`,
      },
      {
        state: data.local_dns_status ? 'success' : 'error',
        key: _('Local DNS'),
        value: data.local_dns_status ? _('Enabled') : _('Failed'),
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('DNS checks failed');
  }
}
