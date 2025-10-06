import { executeShellCommand } from '../../helpers';

export async function getPodkopStatus(): Promise<{
  enabled: number;
  status: string;
}> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['get_status'],
    timeout: 1000,
  });

  if (response.stdout) {
    return JSON.parse(response.stdout.replace(/\n/g, '')) as {
      enabled: number;
      status: string;
    };
  }

  return { enabled: 0, status: 'unknown' };
}
