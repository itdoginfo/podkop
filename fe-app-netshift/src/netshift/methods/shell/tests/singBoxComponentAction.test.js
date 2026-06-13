import { afterEach, describe, expect, it, vi } from 'vitest';

// `methods/shell/index.ts` (and its `callBaseMethod` import) pull in the
// `../../../helpers` barrel, which transitively loads `withTimeout` →
// `../netshift` → `TabService`, whose constructor calls `new MutationObserver`
// at module-init time. In the node test env that throws
// "MutationObserver is not defined" at COLLECT time. Mocking the helpers barrel
// here short-circuits that chain so we can import and exercise the REAL
// `singBoxComponentAction` method while controlling its `executeShellCommand`.
const executeShellCommand = vi.fn();

vi.mock('../../../../helpers', () => ({
  executeShellCommand: (...args) => executeShellCommand(...args),
}));

// Avoid pulling the real `callBaseMethod` (also imports the helpers barrel and
// the LuCI types); the start-failure path under test never reaches it.
vi.mock('../../callBaseMethod', () => ({
  callBaseMethod: vi.fn(),
}));

const { NetShiftShellMethods } = await import('../index');

afterEach(() => {
  executeShellCommand.mockReset();
});

describe('singBoxComponentAction (start-failure path)', () => {
  it('fails fast on start success:false WITHOUT entering the poll loop', async () => {
    executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: false,
        message: 'binary updater is busy',
      }),
      stderr: '',
    });

    const result =
      await NetShiftShellMethods.singBoxComponentAction('install_extended');

    expect(result).toEqual({
      success: false,
      message: 'binary updater is busy',
    });
    // Only the async-start call ran; no `component_action_status` polls.
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
    expect(executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'sing_box', 'install_extended'],
    });
  });

  it('fails fast when the start response has no job_id', async () => {
    executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({ success: true }),
      stderr: '',
    });

    const result =
      await NetShiftShellMethods.singBoxComponentAction('install_stable');

    expect(result.success).toBe(false);
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });

  it('surfaces stderr / generic message when start output is unparseable', async () => {
    executeShellCommand.mockResolvedValueOnce({
      stdout: 'not json',
      stderr: 'boom',
    });

    const result =
      await NetShiftShellMethods.singBoxComponentAction('install_extended');

    expect(result.success).toBe(false);
    expect(result.message).toBe('boom');
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });
});
