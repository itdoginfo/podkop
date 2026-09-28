import { afterEach, describe, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../executeShellCommand';

// The netshift barrel starts TabService, which needs a DOM; withTimeout only
// logs through it.
vi.mock('../../netshift', () => ({ logger: { info: () => undefined } }));

function stubExec(exec: () => Promise<unknown>) {
  vi.stubGlobal('fs', { exec });
}

describe('executeShellCommand', () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('returns the command output', async () => {
    stubExec(async () => ({ stdout: 'ok', stderr: '', code: 0 }));

    await expect(
      executeShellCommand({ command: '/usr/bin/netshift', args: ['x'] }),
    ).resolves.toEqual({ stdout: 'ok', stderr: '', code: 0 });
  });

  it('resolves with the timeout message instead of rejecting', async () => {
    vi.useFakeTimers();
    stubExec(() => new Promise(() => undefined));

    const result = executeShellCommand({
      command: '/usr/bin/netshift',
      args: ['clash_api', 'get_proxies'],
      timeout: 15000,
    });

    await vi.advanceTimersByTimeAsync(15000);

    await expect(result).resolves.toEqual({
      stdout: '',
      stderr: 'Operation timed out',
      code: 0,
    });
  });

  it('resolves with the error message of a failed call', async () => {
    stubExec(async () => {
      throw new Error('Access denied');
    });

    await expect(
      executeShellCommand({ command: '/usr/bin/netshift', args: ['x'] }),
    ).resolves.toEqual({ stdout: '', stderr: 'Access denied', code: 0 });
  });
});
