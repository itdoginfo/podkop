import { describe, expect, it } from 'vitest';
import { getPodkopVersionRow } from '../helpers/getPodkopVersionRow';
import type { StoreType } from '../../../services/store.service';

function makeDiagnosticsSystemInfo(
  patch: Partial<StoreType['diagnosticsSystemInfo']> = {},
): StoreType['diagnosticsSystemInfo'] {
  return {
    loading: false,
    podkop_version: '1.2.3',
    podkop_latest_version: '1.2.3',
    luci_app_version: '1.0.0',
    sing_box_version: '1.11.0',
    openwrt_version: 'OpenWrt 25.12',
    device_model: 'Test Router',
    ...patch,
  };
}

describe('getPodkopVersionRow', () => {
  it('returns Latest when versions differ only by leading v', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: 'v1.2.3',
        podkop_latest_version: '1.2.3',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop',
      value: 'v1.2.3',
      tag: {
        label: 'Latest',
        kind: 'success',
      },
    });
  });

  it('returns Outdated when versions differ', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '1.2.2',
        podkop_latest_version: '1.2.3',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop',
      value: '1.2.2',
      tag: {
        label: 'Outdated',
        kind: 'warning',
      },
    });
  });

  it('returns plain row without tag for dev build', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: 'COMPILED_VERSION',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop',
      value: 'dev',
    });
  });
});
