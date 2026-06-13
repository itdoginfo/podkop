import { NetShift } from '../../types';

const VALID_STATUSES: NetShift.ComponentUpdateStatus[] = [
  'latest',
  'outdated',
  'dev',
  'not_installed',
];

function normalizeStatus(
  status: unknown,
): NetShift.ComponentUpdateStatus | undefined {
  if (
    typeof status === 'string' &&
    (VALID_STATUSES as string[]).includes(status)
  ) {
    return status as NetShift.ComponentUpdateStatus;
  }

  return undefined;
}

/**
 * Parse the STABLE JSON echoed by the sync update-check actions
 * (`component_action sing_box check_update` /
 * `component_action sing_box check_update_stable`):
 * `{success, current_version, latest_version, status}`.
 *
 * Pure (types-only import) so it is unit-testable without dragging in the
 * helpers barrel (which pulls TabService → MutationObserver and crashes the
 * node test env at collect time).
 */
export function parseComponentCheckUpdate(
  stdout: string,
): NetShift.ComponentCheckUpdateResult {
  try {
    const parsed = JSON.parse(stdout) as Record<string, unknown>;

    return {
      success: Boolean(parsed.success),
      current_version:
        typeof parsed.current_version === 'string'
          ? parsed.current_version
          : undefined,
      latest_version:
        typeof parsed.latest_version === 'string'
          ? parsed.latest_version
          : undefined,
      status: normalizeStatus(parsed.status),
      message: typeof parsed.message === 'string' ? parsed.message : undefined,
    };
  } catch (_e) {
    return {
      success: false,
      message: stdout,
    };
  }
}
