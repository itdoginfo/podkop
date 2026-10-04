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

  it('passes a warning through on success and on failure', async () => {
    const warned = await pollSingBoxComponentAction(
      makeFetchStatus([
        {
          running: false,
          success: true,
          version: '1.12.4',
          warning: 'apk world pins sing-box',
          exit_code: 0,
        },
      ]),
      noSleep,
    );

    expect(warned.success).toBe(true);
    expect(warned.warning).toBe('apk world pins sing-box');

    const failed = await pollSingBoxComponentAction(
      makeFetchStatus([
        {
          running: false,
          success: false,
          message: 'previous binary restored',
          warning: 'apk world pins sing-box',
          exit_code: 1,
        },
      ]),
      noSleep,
    );

    expect(failed.success).toBe(false);
    expect(failed.warning).toBe('apk world pins sing-box');
  });

  it('propagates the lite install build flavour and warning code', async () => {
    // Terminal state of an extended-lite install: build + the machine-readable
    // upx_ram_spike code ride the same job-status JSON as version/warning.
    const result = await pollSingBoxComponentAction(
      makeFetchStatus([
        {
          running: false,
          success: true,
          version: '1.14.1-extended-2.7.2-lite',
          warning: 'upx_ram_spike',
          build: 'compressed',
          exit_code: 0,
        },
      ]),
      noSleep,
    );

    expect(result).toEqual({
      success: true,
      version: '1.14.1-extended-2.7.2-lite',
      warning: 'upx_ram_spike',
      build: 'compressed',
    });
  });

  it('normalizes an empty or unknown build flavour to undefined', async () => {
    const empty = await pollSingBoxComponentAction(
      makeFetchStatus([
        { running: false, success: true, version: '1.12.4', build: '' },
      ]),
      noSleep,
    );

    expect(empty.build).toBeUndefined();

    const weird = await pollSingBoxComponentAction(
      makeFetchStatus([
        { running: false, success: true, version: '1.12.4', build: 'tar' },
      ]),
      noSleep,
    );

    expect(weird.build).toBeUndefined();
  });

  it('reports no warning when the job state carries an empty one', async () => {
    const result = await pollSingBoxComponentAction(
      makeFetchStatus([
        { running: false, success: true, version: '1.12.4', warning: '' },
      ]),
      noSleep,
    );

    expect(result.warning).toBeUndefined();
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

  it('words the poll-level failures with the caller messages when given', async () => {
    const messages = { failed: 'status unreadable', timedOut: 'too slow' };

    const failed = await pollSingBoxComponentAction(
      makeFetchStatus([null]),
      noSleep,
      0,
      5,
      messages,
    );
    const timedOut = await pollSingBoxComponentAction(
      vi.fn(async () => ({ running: true, success: true })),
      noSleep,
      0,
      3,
      messages,
    );

    expect(failed).toEqual({ success: false, message: 'status unreadable' });
    expect(timedOut).toEqual({ success: false, message: 'too slow' });
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
