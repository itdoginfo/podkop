import { afterEach, describe, expect, it, vi } from 'vitest';

// The section's "Check servers" button passes `--section <section>` and the
// servers; they have to reach the backend command line (the real
// callBaseMethod, only executeShellCommand is stubbed).
const executeShellCommand = vi.fn();

vi.mock('../../../../helpers', () => ({
  executeShellCommand: (...args) => executeShellCommand(...args),
}));

const { NetShiftShellMethods } = await import('../index');

afterEach(() => {
  executeShellCommand.mockReset();
});

describe('dnsBenchmark', () => {
  it('passes --section and the servers of the section to the backend', async () => {
    executeShellCommand.mockResolvedValue({
      stdout: '{"via":"direct","results":[]}',
      stderr: '',
    });

    await NetShiftShellMethods.dnsBenchmark([
      '--section',
      'main',
      'udp://10.0.0.1',
      'dot://dns.example',
    ]);

    expect(executeShellCommand).toHaveBeenCalledTimes(1);
    expect(executeShellCommand.mock.calls[0][0].args).toEqual([
      'dns_benchmark',
      '--section',
      'main',
      'udp://10.0.0.1',
      'dot://dns.example',
    ]);
  });

  it('asks for the servers of the settings without arguments', async () => {
    executeShellCommand.mockResolvedValue({ stdout: '{}', stderr: '' });

    await NetShiftShellMethods.dnsBenchmark();

    expect(executeShellCommand.mock.calls[0][0].args).toEqual([
      'dns_benchmark',
    ]);
  });
});
