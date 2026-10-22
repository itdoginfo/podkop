import { beforeEach, describe, expect, it, vi } from 'vitest';

const { executeShellCommand } = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({ executeShellCommand }));

import { callBaseMethod } from '../callBaseMethod';

describe('callBaseMethod', () => {
  beforeEach(() => {
    executeShellCommand.mockReset();
    executeShellCommand.mockResolvedValue({ stdout: '{"a":1}', stderr: '' });
  });

  it('keeps the 15 second timeout when none is asked for', async () => {
    await callBaseMethod('check_route' as never, ['x']);

    expect(executeShellCommand.mock.calls[0][0].timeout).toBe(15000);
  });

  it('passes the timeout of a slow call to the shell command', async () => {
    await callBaseMethod('support_report' as never, [], undefined, {
      nobatch: true,
      timeout: 25000,
    });

    const call = executeShellCommand.mock.calls[0][0];

    expect(call.timeout).toBe(25000);
    expect(call.nobatch).toBe(true);
  });
});
