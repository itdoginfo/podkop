import { normalizeCompiledVersion } from '../../../../helpers/normalizeCompiledVersion';
import { removeVersionPrefix } from '../../../../helpers/removeVersionPrefix';
import type { StoreType } from '../../../services/store.service';
import type { IRenderSystemInfoRow } from '../partials';

function isUnknownVersion(version?: string | null): boolean {
  return version === 'unknown' || version === _('unknown');
}

export function getNetshiftVersionRow(
  diagnosticsSystemInfo: StoreType['diagnosticsSystemInfo'],
): IRenderSystemInfoRow {
  const loading = diagnosticsSystemInfo.loading;
  const unknown = isUnknownVersion(diagnosticsSystemInfo.netshift_version);
  const hasActualVersion =
    Boolean(diagnosticsSystemInfo.netshift_latest_version) &&
    !isUnknownVersion(diagnosticsSystemInfo.netshift_latest_version);
  const version = normalizeCompiledVersion(
    diagnosticsSystemInfo.netshift_version,
  );
  const isDevVersion = version === 'dev';

  if (loading || unknown || !hasActualVersion || isDevVersion) {
    return {
      key: 'NetShift',
      value: version,
    };
  }

  if (
    removeVersionPrefix(version) !==
    removeVersionPrefix(diagnosticsSystemInfo.netshift_latest_version)
  ) {
    return {
      key: 'NetShift',
      value: version,
      tag: {
        label: _('Outdated'),
        kind: 'warning',
      },
    };
  }

  return {
    key: 'NetShift',
    value: version,
    tag: {
      label: _('Latest'),
      kind: 'success',
    },
  };
}
