import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import { StoreType } from '../../services';

export const initialDiagnosticStore: Pick<
  StoreType,
  | 'diagnosticsChecks'
  | 'diagnosticsRunAction'
  | 'diagnosticsActions'
  | 'diagnosticsSystemInfo'
> = {
  diagnosticsSystemInfo: {
    loading: true,
    podkop_version: 'loading',
    podkop_latest_version: 'loading',
    luci_app_version: 'loading',
    sing_box_version: 'loading',
    openwrt_version: 'loading',
    device_model: 'loading',
  },
  diagnosticsActions: {
    restart: {
      loading: false,
    },
    start: {
      loading: false,
    },
    stop: {
      loading: false,
    },
    enable: {
      loading: false,
    },
    disable: {
      loading: false,
    },
    globalCheck: {
      loading: false,
    },
    viewLogs: {
      loading: false,
    },
    showSingBoxConfig: {
      loading: false,
    },
  },
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
      code: DIAGNOSTICS_CHECKS.OUTBOUNDS,
      title: DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS.title,
      order: DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS.order,
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
      description: _('Pending'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.SINGBOX,
      title: DIAGNOSTICS_CHECKS_MAP.SINGBOX.title,
      order: DIAGNOSTICS_CHECKS_MAP.SINGBOX.order,
      description: _('Pending'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.NFT,
      title: DIAGNOSTICS_CHECKS_MAP.NFT.title,
      order: DIAGNOSTICS_CHECKS_MAP.NFT.order,
      description: _('Pending'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.OUTBOUNDS,
      title: DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS.title,
      order: DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS.order,
      description: _('Pending'),
      items: [],
      state: 'skipped',
    },
    {
      code: DIAGNOSTICS_CHECKS.FAKEIP,
      title: DIAGNOSTICS_CHECKS_MAP.FAKEIP.title,
      order: DIAGNOSTICS_CHECKS_MAP.FAKEIP.order,
      description: _('Pending'),
      items: [],
      state: 'skipped',
    },
  ],
};
