import { describe, expect, it } from 'vitest';
import { getNetshiftVersionRow } from '../helpers/getNetshiftVersionRow';
import type { StoreType } from '../../../services/store.service';

function makeDiagnosticsSystemInfo(
  patch: Partial<StoreType['diagnosticsSystemInfo']> = {},
): StoreType['diagnosticsSystemInfo'] {
  return {
    loading: false,
    netshift_version: '1.2.3',
    netshift_latest_version: '1.2.3',
    luci_app_version: '1.0.0',
    sing_box_version: '1.11.0',
    openwrt_version: 'OpenWrt 25.12',
    device_model: 'Test Router',
    sing_box_extended: 0,
    sing_box_variant: 'stock',
    sing_box_lite_upx: 0,
    sing_box_lite_supported: 1,
    ...patch,
  };
}

describe('getNetshiftVersionRow', () => {
  it('returns Latest when versions differ only by leading v', () => {
    const row = getNetshiftVersionRow(
      makeDiagnosticsSystemInfo({
        netshift_version: 'v1.2.3',
        netshift_latest_version: '1.2.3',
      }),
    );

    expect(row).toEqual({
      key: 'NetShift',
      value: 'v1.2.3',
      tag: {
        label: 'Latest',
        kind: 'success',
      },
    });
  });

  it('returns Outdated when versions differ', () => {
    const row = getNetshiftVersionRow(
      makeDiagnosticsSystemInfo({
        netshift_version: '1.2.2',
        netshift_latest_version: '1.2.3',
      }),
    );

    expect(row).toEqual({
      key: 'NetShift',
      value: '1.2.2',
      tag: {
        label: 'Outdated',
        kind: 'warning',
      },
    });
  });

  it('returns plain row without tag for dev build', () => {
    const row = getNetshiftVersionRow(
      makeDiagnosticsSystemInfo({
        netshift_version: 'COMPILED_VERSION',
      }),
    );

    expect(row).toEqual({
      key: 'NetShift',
      value: 'dev',
    });
  });
});
