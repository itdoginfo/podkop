import { getDNSCheck } from '../../../methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';
import { insertIf } from '../../../../helpers';
import { IDiagnosticsChecksItem } from '../../../../store';

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
      ...insertIf<IDiagnosticsChecksItem>(
        data.dns_type === 'doh' || data.dns_type === 'dot',
        [
          {
            state: data.bootstrap_dns_status ? 'success' : 'error',
            key: _('Bootsrap DNS'),
            value: `${data.bootstrap_dns_server} ${data.bootstrap_dns_status ? '✅' : '❌'}`,
          },
        ],
      ),
      {
        state: data.dns_status ? 'success' : 'error',
        key: _('Main DNS'),
        value: `${data.dns_server} [${data.dns_type}] ${data.dns_status ? '✅' : '❌'}`,
      },
      {
        state: data.local_dns_status ? 'success' : 'error',
        key: _('Local DNS'),
        value: data.local_dns_status ? '✅' : '❌',
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('DNS checks failed');
  }
}
