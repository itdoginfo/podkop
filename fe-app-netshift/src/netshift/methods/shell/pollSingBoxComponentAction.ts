import { sleep } from './sleep';

export interface SingBoxComponentActionResult {
  success: boolean;
  version?: string;
  message?: string;
  // Something the user has to fix by hand whatever the outcome, e.g. a pin
  // the stable core switch had to leave in the apk world — or the lite
  // installer's machine-readable 'upx_ram_spike' code.
  warning?: string;
  // Extended-lite installs only: the flavour that was installed
  // ('elf' | 'compressed'); absent for the other cores.
  build?: 'elf' | 'compressed';
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
  warning?: string;
  // Extended-lite installs only: the installed flavour ('elf'/'compressed').
  build?: string;
}

// What the poll reports when it cannot tell how the job ended. The loop is
// shared by every async component action, so a caller that is not the core
// switch passes its own wording.
export interface ComponentActionPollMessages {
  failed: string;
  timedOut: string;
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

// The async job state carries build as '""' when the worker did not report
// one (non-lite cores) — normalize to the closed result union.
function normalizeResultBuild(
  build: string | undefined,
): 'elf' | 'compressed' | undefined {
  return build === 'elf' || build === 'compressed' ? build : undefined;
}

/**
 * Pure poll loop for the async core switch. Each `fetchStatus` call is a tiny,
 * individual `component_action_status` exec (well under the rpcd 30s wall); the
 * loop runs until the job is no longer running (a parse failure or
 * `running === false` is terminal). `sleepFn` is injected so tests can avoid
 * real 2s waits. `messages` replaces the core-switch wording of the two
 * poll-level failures (unreadable status, backstop reached).
 */
export async function pollSingBoxComponentAction(
  fetchStatus: () => Promise<ComponentActionStatus | null>,
  sleepFn: (ms: number) => Promise<void> = sleep,
  intervalMs: number = POLL_INTERVAL_MS,
  maxPolls: number = MAX_POLLS,
  messages?: ComponentActionPollMessages,
): Promise<SingBoxComponentActionResult> {
  for (let poll = 0; poll < maxPolls; poll += 1) {
    const status = await fetchStatus();

    // A parse failure (null) is terminal — we cannot keep polling blindly.
    if (!status) {
      return {
        success: false,
        message: messages?.failed ?? _('Core switch failed'),
      };
    }

    if (status.running !== true) {
      return {
        success: Boolean(status.success),
        version: status.version,
        message: status.message,
        warning: status.warning || undefined,
        build: normalizeResultBuild(status.build),
      };
    }

    await sleepFn(intervalMs);
  }

  return {
    success: false,
    message: messages?.timedOut ?? _('Core switch timed out'),
  };
}
