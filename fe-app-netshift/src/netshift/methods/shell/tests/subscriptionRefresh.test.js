import { afterEach, describe, expect, it, vi } from 'vitest';

// Same collect-time isolation as singBoxComponentAction.test.js: the helpers
// barrel pulls in TabService (MutationObserver), so it is mocked and only
// `executeShellCommand` is controlled here.
const executeShellCommand = vi.fn();

vi.mock('../../../../helpers', () => ({
  executeShellCommand: (...args) => executeShellCommand(...args),
}));

vi.mock('../../callBaseMethod', () => ({
  callBaseMethod: vi.fn(),
}));

const { NetShiftShellMethods } = await import('../index');

function started(jobId = 'job-1') {
  return {
    stdout: JSON.stringify({ success: true, job_id: jobId }),
    stderr: '',
  };
}

function finished(status) {
  return { stdout: JSON.stringify({ running: false, ...status }), stderr: '' };
}

afterEach(() => {
  executeShellCommand.mockReset();
});

describe('subscription refresh (dashboard buttons)', () => {
  it('refreshAllSubscriptions starts `subscription update` with no extra arguments', async () => {
    executeShellCommand
      .mockResolvedValueOnce(started())
      .mockResolvedValueOnce(
        finished({ success: true, message: 'All subscriptions updated' }),
      );

    const result = await NetShiftShellMethods.refreshAllSubscriptions();

    expect(executeShellCommand).toHaveBeenNthCalledWith(1, {
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'subscription', 'update'],
    });
    expect(executeShellCommand).toHaveBeenNthCalledWith(2, {
      command: '/usr/bin/netshift',
      args: ['component_action_status', 'job-1'],
    });
    expect(result.success).toBe(true);
    expect(result.message).toBe('All subscriptions updated');
  });

  it('refreshSubscriptionFeed passes the section and the feed block tag as separate arguments', async () => {
    executeShellCommand
      .mockResolvedValueOnce(started())
      .mockResolvedValueOnce(finished({ success: true }));

    await NetShiftShellMethods.refreshSubscriptionFeed(
      'my sub',
      '⚡ feed.example.com-1',
    );

    expect(executeShellCommand).toHaveBeenNthCalledWith(1, {
      command: '/usr/bin/netshift',
      args: [
        'component_action_async',
        'subscription',
        'update_feed',
        'my sub',
        '⚡ feed.example.com-1',
      ],
    });
  });

  it('refreshSubscriptionFeed without a feed asks for the whole section', async () => {
    executeShellCommand
      .mockResolvedValueOnce(started())
      .mockResolvedValueOnce(finished({ success: true }));

    await NetShiftShellMethods.refreshSubscriptionFeed('main');

    expect(executeShellCommand).toHaveBeenNthCalledWith(1, {
      command: '/usr/bin/netshift',
      args: ['component_action_async', 'subscription', 'update_feed', 'main'],
    });
  });

  it('surfaces the backend message of a failed job (e.g. another update running)', async () => {
    executeShellCommand.mockResolvedValueOnce(started()).mockResolvedValueOnce(
      finished({
        success: false,
        message: 'Another subscription update is already running',
      }),
    );

    const result = await NetShiftShellMethods.refreshSubscriptionFeed('main');

    expect(result).toMatchObject({
      success: false,
      message: 'Another subscription update is already running',
    });
  });

  it('fails fast when the job does not start, without polling', async () => {
    executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({ success: false, message: 'no state dir' }),
      stderr: '',
    });

    const result = await NetShiftShellMethods.refreshAllSubscriptions();

    expect(result).toEqual({ success: false, message: 'no state dir' });
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });

  it('reports an unreadable status in subscription words, not as a core switch', async () => {
    executeShellCommand
      .mockResolvedValueOnce(started())
      .mockResolvedValueOnce({ stdout: 'not json', stderr: '' });

    const result = await NetShiftShellMethods.refreshSubscriptionFeed('main');

    expect(result).toEqual({
      success: false,
      message: 'Failed to read the subscription update status',
    });
  });
});
