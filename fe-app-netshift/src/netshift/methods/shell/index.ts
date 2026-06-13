import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, NetShift } from '../../types';
import { executeShellCommand } from '../../../helpers';
import {
  ComponentActionStartResponse,
  ComponentActionStatus,
  SingBoxComponentActionResult,
  parseComponentActionStatus,
  pollSingBoxComponentAction,
} from './pollSingBoxComponentAction';
import { parseComponentCheckUpdate } from './parseComponentCheckUpdate';

export const NetShiftShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<NetShift.DnsCheckResult>(
      NetShift.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<NetShift.FakeIPCheckResult>(
      NetShift.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<NetShift.NftRulesCheckResult>(
      NetShift.AvailableMethods.CHECK_NFT_RULES,
    ),
  getStatus: async () =>
    callBaseMethod<NetShift.GetStatus>(NetShift.AvailableMethods.GET_STATUS),
  checkSingBox: async () =>
    callBaseMethod<NetShift.SingBoxCheckResult>(
      NetShift.AvailableMethods.CHECK_SING_BOX,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<NetShift.GetSingBoxStatus>(
      NetShift.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(NetShift.AvailableMethods.CLASH_API, [
      NetShift.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiProxyLatency: async (tag: string) =>
    callBaseMethod<NetShift.GetClashApiProxyLatency>(
      NetShift.AvailableMethods.CLASH_API,
      [NetShift.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, '5000'],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<NetShift.GetClashApiGroupLatency>(
      NetShift.AvailableMethods.CLASH_API,
      [NetShift.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(NetShift.AvailableMethods.CLASH_API, [
      NetShift.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  restart: async () =>
    callBaseMethod<unknown>(
      NetShift.AvailableMethods.RESTART,
      [],
      '/etc/init.d/netshift',
    ),
  start: async () =>
    callBaseMethod<unknown>(
      NetShift.AvailableMethods.START,
      [],
      '/etc/init.d/netshift',
    ),
  stop: async () =>
    callBaseMethod<unknown>(
      NetShift.AvailableMethods.STOP,
      [],
      '/etc/init.d/netshift',
    ),
  enable: async () =>
    callBaseMethod<unknown>(
      NetShift.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/netshift',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      NetShift.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/netshift',
    ),
  globalCheck: async () =>
    callBaseMethod<unknown>(NetShift.AvailableMethods.GLOBAL_CHECK),
  showSingBoxConfig: async () =>
    callBaseMethod<unknown>(NetShift.AvailableMethods.SHOW_SING_BOX_CONFIG),
  checkLogs: async () =>
    callBaseMethod<unknown>(NetShift.AvailableMethods.CHECK_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<NetShift.GetSystemInfo>(
      NetShift.AvailableMethods.GET_SYSTEM_INFO,
    ),
  subscriptionUpdate: async () =>
    callBaseMethod<unknown>(NetShift.AvailableMethods.SUBSCRIPTION_UPDATE),
  singBoxComponentAction: async (
    action: 'install_extended' | 'install_stable' | 'check_update',
  ): Promise<SingBoxComponentActionResult> => {
    // `check_update` is a quick single call — not subject to the rpcd 30s wall —
    // so keep it on the SYNCHRONOUS `component_action` path (unchanged shape).
    if (action === 'check_update') {
      const response = await executeShellCommand({
        command: '/usr/bin/netshift',
        args: ['component_action', 'sing_box', action],
        timeout: 600000,
      });

      if (response.stdout) {
        try {
          const parsed = JSON.parse(
            response.stdout,
          ) as SingBoxComponentActionResult;

          return {
            success: Boolean(parsed.success),
            version: parsed.version,
            message: parsed.message,
          };
        } catch (_e) {
          return {
            success: false,
            message: response.stdout,
          };
        }
      }

      return {
        success: false,
        message: response.stderr || '',
      };
    }

    // Install actions can take minutes — drive the async backend contract:
    // start the job, then poll `component_action_status` with short execs so
    // rpcd never kills a single long-running call.
    const startResponse = await executeShellCommand({
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'sing_box', action],
    });

    let start: ComponentActionStartResponse | null = null;

    if (startResponse.stdout) {
      try {
        start = JSON.parse(
          startResponse.stdout,
        ) as ComponentActionStartResponse;
      } catch (_e) {
        start = null;
      }
    }

    if (!start || start.success !== true || !start.job_id) {
      return {
        success: false,
        message:
          start?.message || startResponse.stderr || _('Core switch failed'),
      };
    }

    const jobId = start.job_id;

    return pollSingBoxComponentAction(async () => {
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/netshift',
        args: ['component_action_status', jobId],
      });

      if (!statusResponse.stdout) {
        return null;
      }

      return parseComponentActionStatus(statusResponse.stdout);
    });
  },
  // Sing-box update checks (sync) — STABLE task-017 contract:
  //   component_action sing_box check_update        (extended)
  //   component_action sing_box check_update_stable (stock)
  // → {success, current_version, latest_version, status}.
  singBoxCheckUpdate: async (
    action: 'check_update' | 'check_update_stable',
  ): Promise<NetShift.ComponentCheckUpdateResult> => {
    const response = await executeShellCommand({
      command: '/usr/bin/netshift',
      args: ['component_action', 'sing_box', action],
      timeout: 600000,
    });

    if (response.stdout) {
      return parseComponentCheckUpdate(response.stdout);
    }

    return {
      success: false,
      message: response.stderr || '',
    };
  },
  // NetShift update check (sync) — task-029/030 contract:
  //   component_action netshift check_update
  // → {success, current_version, latest_version, status}. Same shape as the
  // sing-box cores (parsed by parseComponentCheckUpdate). The status is already
  // v-normalized server-side, so the caller TRUSTS result.status (no string
  // compare in TS). Stays on the SYNC component_action path (fast call).
  netshiftCheckUpdate:
    async (): Promise<NetShift.ComponentCheckUpdateResult> => {
      const response = await executeShellCommand({
        command: '/usr/bin/netshift',
        args: ['component_action', 'netshift', 'check_update'],
        timeout: 600000,
      });

      if (response.stdout) {
        return parseComponentCheckUpdate(response.stdout);
      }

      return {
        success: false,
        message: response.stderr || '',
      };
    },
  // Clear subscription cache (async) — task-039/040 contract:
  // component_action_async subscription clear_cache + component_action_status
  // <job>. Deletes all subscription caches then re-downloads, which restarts
  // the service and can exceed the rpcd ~30s wall — so it MUST run through the
  // SAME async start+poll mechanism as the sing-box core switch (reusing the
  // component-agnostic `pollSingBoxComponentAction`). The component/action
  // strings are EXACTLY 'subscription'/'clear_cache' (match task-039's router).
  clearSubscriptionCache: async (): Promise<SingBoxComponentActionResult> => {
    const startResponse = await executeShellCommand({
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'subscription', 'clear_cache'],
    });

    let start: ComponentActionStartResponse | null = null;

    if (startResponse.stdout) {
      try {
        start = JSON.parse(
          startResponse.stdout,
        ) as ComponentActionStartResponse;
      } catch (_e) {
        start = null;
      }
    }

    if (!start || start.success !== true || !start.job_id) {
      return {
        success: false,
        message:
          start?.message ||
          startResponse.stderr ||
          _('Failed to clear subscription cache'),
      };
    }

    const jobId = start.job_id;

    return pollSingBoxComponentAction(async () => {
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/netshift',
        args: ['component_action_status', jobId],
      });

      if (!statusResponse.stdout) {
        return null;
      }

      return parseComponentActionStatus(statusResponse.stdout);
    });
  },
  // NetShift self-update (async) — STABLE task-017 contract:
  // component_action_async netshift self_update + component_action_status <job>.
  // Reuses the component-agnostic poll. Because the package install swaps
  // /usr/bin/netshift mid-job, status polls can transiently fail (rpcd / binary
  // swap); once the job has STARTED we treat such failures leniently — keep
  // polling (return a synthetic running status) instead of aborting hard, so a
  // successful self-update is not misreported as a failure. The UI reloads the
  // page on success.
  netshiftSelfUpdate: async (): Promise<SingBoxComponentActionResult> => {
    const startResponse = await executeShellCommand({
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'netshift', 'self_update'],
    });

    let start: ComponentActionStartResponse | null = null;

    if (startResponse.stdout) {
      try {
        start = JSON.parse(
          startResponse.stdout,
        ) as ComponentActionStartResponse;
      } catch (_e) {
        start = null;
      }
    }

    if (!start || start.success !== true || !start.job_id) {
      return {
        success: false,
        message:
          start?.message || startResponse.stderr || _('Self-update failed'),
      };
    }

    const jobId = start.job_id;

    return pollSingBoxComponentAction(async () => {
      // Lenient mid-job polling: any exec/parse error AFTER a successful start
      // is reported as "still running" so the binary swap doesn't end the loop
      // prematurely. The MAX_POLLS backstop still bounds the loop.
      try {
        const statusResponse = await executeShellCommand({
          command: '/usr/bin/netshift',
          args: ['component_action_status', jobId],
        });

        if (!statusResponse.stdout) {
          return { running: true } as ComponentActionStatus;
        }

        return (
          parseComponentActionStatus(statusResponse.stdout) ??
          ({ running: true } as ComponentActionStatus)
        );
      } catch (_e) {
        return { running: true } as ComponentActionStatus;
      }
    });
  },
};
