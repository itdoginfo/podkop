import { getDNSCheck } from '../../../methods';
import { updateDiagnosticsCheck } from '../updateDiagnosticsCheck';
import { insertIf } from '../../../../helpers';
import { IDiagnosticsChecksItem } from '../../../../store';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';

export async function runDnsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.DNS;

  updateDiagnosticsCheck({
    order,
    code,
    title,
    description: _('Checking dns, please wait'),
    state: 'loading',
    items: [],
  });

  const dnsChecks = await getDNSCheck();

  if (!dnsChecks.success) {
    updateDiagnosticsCheck({
      order,
      code,
      title,
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
    order,
    code,
    title,
    description: _('DNS checks passed'),
    state: getStatus(),
    items: [
      ...insertIf<IDiagnosticsChecksItem>(
        data.dns_type === 'doh' || data.dns_type === 'dot',
        [
          {
            state: data.bootstrap_dns_status ? 'success' : 'error',
            key: _('Bootsrap DNS'),
            value: data.bootstrap_dns_server,
          },
        ],
      ),
      {
        state: data.dns_status ? 'success' : 'error',
        key: _('Main DNS'),
        value: `${data.dns_server} [${data.dns_type}]`,
      },
      {
        state: data.local_dns_status ? 'success' : 'error',
        key: _('Local DNS'),
        value: '',
      },
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('DNS checks failed');
  }
}
