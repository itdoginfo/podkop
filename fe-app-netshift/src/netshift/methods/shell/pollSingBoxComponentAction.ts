import { sleep } from './sleep';

export interface SingBoxComponentActionResult {
  success: boolean;
  version?: string;
  message?: string;
}

// Shape echoed by `component_action_async sing_box <action>` on start.
export interface ComponentActionStartResponse {
  success?: boolean;
  job_id?: string;
  message?: string;
}

// Shape echoed by `component_action_status <job_id>` (task-007/009 contract).
export interface ComponentActionStatus {
  success?: boolean;
  running?: boolean;
  component?: string;
  action?: string;
  message?: string;
  pid?: number | null;
  started_at?: number;
  updated_at?: number;
  exit_code?: number | null;
  version?: string;
  latest_version?: string;
}

// ~2s between polls; ~150 polls ≈ 5 min backstop against a wedged job.
export const POLL_INTERVAL_MS = 2000;
export const MAX_POLLS = 150;

export function parseComponentActionStatus(
  stdout: string,
): ComponentActionStatus | null {
  try {
    return JSON.parse(stdout) as ComponentActionStatus;
  } catch (_e) {
    return null;
  }
}

/**
 * Pure poll loop for the async core switch. Each `fetchStatus` call is a tiny,
 * individual `component_action_status` exec (well under the rpcd 30s wall); the
 * loop runs until the job is no longer running (a parse failure or
 * `running === false` is terminal). `sleepFn` is injected so tests can avoid
 * real 2s waits.
 */
export async function pollSingBoxComponentAction(
  fetchStatus: () => Promise<ComponentActionStatus | null>,
  sleepFn: (ms: number) => Promise<void> = sleep,
  intervalMs: number = POLL_INTERVAL_MS,
  maxPolls: number = MAX_POLLS,
): Promise<SingBoxComponentActionResult> {
  for (let poll = 0; poll < maxPolls; poll += 1) {
    const status = await fetchStatus();

    // A parse failure (null) is terminal — we cannot keep polling blindly.
    if (!status) {
      return {
        success: false,
        message: _('Core switch failed'),
      };
    }

    if (status.running !== true) {
      return {
        success: Boolean(status.success),
        version: status.version,
        message: status.message,
      };
    }

    await sleepFn(intervalMs);
  }

  return {
    success: false,
    message: _('Core switch timed out'),
  };
}
