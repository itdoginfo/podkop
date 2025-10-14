import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import { StoreType } from '../../../store';

export const initialDiagnosticStore: Pick<
  StoreType,
  'diagnosticsChecks' | 'diagnosticsRunAction'
> = {
  diagnosticsRunAction: { loading: false },
  diagnosticsChecks: [
    {
      code: DIAGNOSTICS_CHECKS.DNS,
      title: DIAGNOSTICS_CHECKS_MAP.DNS.title,
      order: DIAGNOSTICS_CHECKS_MAP.DNS.order,
      description: _('Not running'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.SINGBOX,
      title: DIAGNOSTICS_CHECKS_MAP.SINGBOX.title,
      order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
      description: _('Not running'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.NFT,
      title: DIAGNOSTICS_CHECKS_MAP.NFT.title,
      order: DIAGNOSTICS_CHECKS_MAP.NFT.order,
      description: _('Not running'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.FAKEIP,
      title: DIAGNOSTICS_CHECKS_MAP.FAKEIP.title,
      order: DIAGNOSTICS_CHECKS_MAP.FAKEIP.order,
      description: _('Not running'),
      items: [],
      state: 'skipped',
    },
  ],
};

export const loadingDiagnosticsChecksStore: Pick<
  StoreType,
  'diagnosticsChecks'
> = {
  diagnosticsChecks: [
    {
      code: DIAGNOSTICS_CHECKS.DNS,
      title: DIAGNOSTICS_CHECKS_MAP.DNS.title,
      order: DIAGNOSTICS_CHECKS_MAP.DNS.order,
      description: _('Queued'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.SINGBOX,
      title: DIAGNOSTICS_CHECKS_MAP.SINGBOX.title,
      order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
      description: _('Queued'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.NFT,
      title: DIAGNOSTICS_CHECKS_MAP.NFT.title,
      order: DIAGNOSTICS_CHECKS_MAP.NFT.order,
      description: _('Queued'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.FAKEIP,
      title: DIAGNOSTICS_CHECKS_MAP.FAKEIP.title,
      order: DIAGNOSTICS_CHECKS_MAP.FAKEIP.order,
      description: _('Queued'),
      items: [],
      state: 'skipped',
    },
  ],
};
