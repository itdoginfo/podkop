import { normalizeCompiledVersion } from '../../../../helpers/normalizeCompiledVersion';
import { removeVersionPrefix } from '../../../../helpers/removeVersionPrefix';
import type { StoreType } from '../../../services/store.service';
import type { IRenderSystemInfoRow } from '../partials';

function isUnknownVersion(version?: string | null): boolean {
  return version === 'unknown' || version === _('unknown');
}

export function getPodkopVersionRow(
  diagnosticsSystemInfo: StoreType['diagnosticsSystemInfo'],
): IRenderSystemInfoRow {
  const loading = diagnosticsSystemInfo.loading;
  const unknown = isUnknownVersion(diagnosticsSystemInfo.podkop_version);
  const hasActualVersion =
    Boolean(diagnosticsSystemInfo.podkop_latest_version) &&
    !isUnknownVersion(diagnosticsSystemInfo.podkop_latest_version);
  const version = normalizeCompiledVersion(
    diagnosticsSystemInfo.podkop_version,
  );
  const isDevVersion = version === 'dev';

  if (loading || unknown || !hasActualVersion || isDevVersion) {
    return {
      key: 'Podkop',
      value: version,
    };
  }

  if (
    removeVersionPrefix(version) !==
    removeVersionPrefix(diagnosticsSystemInfo.podkop_latest_version)
  ) {
    return {
      key: 'Podkop',
      value: version,
      tag: {
        label: _('Outdated'),
        kind: 'warning',
      },
    };
  }

  return {
    key: 'Podkop',
    value: version,
    tag: {
      label: _('Latest'),
      kind: 'success',
    },
  };
}
