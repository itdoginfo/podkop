import { describe, expect, it, vi } from 'vitest';
import { pollSingBoxComponentAction } from '../pollSingBoxComponentAction';

// No-op sleep so polls resolve instantly (no real 2s waits in tests).
const noSleep = () => Promise.resolve();

// Build a fetchStatus callback that returns the queued statuses in order,
// then keeps returning the last one.
function makeFetchStatus(statuses) {
  let index = 0;

  return vi.fn(async () => {
    const status = statuses[Math.min(index, statuses.length - 1)];
    index += 1;

    return status;
  });
}

describe('pollSingBoxComponentAction', () => {
  it('resolves success with version after N running polls then terminal', async () => {
    const fetchStatus = makeFetchStatus([
      { running: true, success: true, exit_code: null },
      { running: true, success: true, exit_code: null },
      {
        running: false,
        success: true,
        version: '1.12.4',
        message: 'Core switched',
        exit_code: 0,
      },
    ]);

    const result = await pollSingBoxComponentAction(fetchStatus, noSleep);

    expect(result).toEqual({
      success: true,
      version: '1.12.4',
      message: 'Core switched',
    });
    // 3 status reads (2 running + 1 terminal).
    expect(fetchStatus).toHaveBeenCalledTimes(3);
  });

  it('surfaces the failure message on terminal success:false', async () => {
    const fetchStatus = makeFetchStatus([
      { running: true, success: true },
      {
        running: false,
        success: false,
        message: 'core switch aborted (existing sing-box left intact)',
        exit_code: 1,
      },
    ]);

    const result = await pollSingBoxComponentAction(fetchStatus, noSleep);

    expect(result.success).toBe(false);
    expect(result.message).toBe(
      'core switch aborted (existing sing-box left intact)',
    );
  });

  it('treats a parse failure (null status) as terminal failure', async () => {
    const fetchStatus = makeFetchStatus([
      { running: true, success: true },
      null,
    ]);

    const result = await pollSingBoxComponentAction(fetchStatus, noSleep);

    expect(result.success).toBe(false);
    expect(result.message).toBe('Core switch failed');
  });

  it('returns timeout when the safety cap is exceeded', async () => {
    // Always running → never terminal.
    const fetchStatus = vi.fn(async () => ({ running: true, success: true }));

    const result = await pollSingBoxComponentAction(fetchStatus, noSleep, 0, 5);

    expect(result.success).toBe(false);
    expect(result.message).toBe('Core switch timed out');
    expect(fetchStatus).toHaveBeenCalledTimes(5);
  });

  it('returns immediately on a terminal-first status', async () => {
    const fetchStatus = makeFetchStatus([
      {
        running: false,
        success: true,
        version: '1.13.0',
        message: 'done',
      },
    ]);

    const result = await pollSingBoxComponentAction(fetchStatus, noSleep);

    expect(result).toEqual({
      success: true,
      version: '1.13.0',
      message: 'done',
    });
    expect(fetchStatus).toHaveBeenCalledTimes(1);
  });
});
