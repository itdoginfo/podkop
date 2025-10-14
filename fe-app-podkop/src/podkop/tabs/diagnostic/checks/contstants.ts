export enum DIAGNOSTICS_CHECKS {
  DNS = 'DNS',
  SINGBOX = 'SINGBOX',
  NFT = 'NFT',
  FAKEIP = 'FAKEIP',
}

export const DIAGNOSTICS_CHECKS_MAP: Record<
  DIAGNOSTICS_CHECKS,
  { order: number; title: string; code: DIAGNOSTICS_CHECKS }
> = {
  [DIAGNOSTICS_CHECKS.DNS]: {
    order: 1,
    title: _('DNS checks'),
    code: DIAGNOSTICS_CHECKS.DNS,
  },
  [DIAGNOSTICS_CHECKS.SINGBOX]: {
    order: 2,
    title: _('Sing-box checks'),
    code: DIAGNOSTICS_CHECKS.SINGBOX,
  },
  [DIAGNOSTICS_CHECKS.NFT]: {
    order: 3,
    title: _('Nftables checks'),
    code: DIAGNOSTICS_CHECKS.NFT,
  },
  [DIAGNOSTICS_CHECKS.FAKEIP]: {
    order: 4,
    title: _('FakeIP checks'),
    code: DIAGNOSTICS_CHECKS.FAKEIP,
  },
};
