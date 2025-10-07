import { executeShellCommand } from '../../helpers';

export async function getSingboxStatus(): Promise<{
  running: number;
  enabled: number;
  status: string;
}> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['get_sing_box_status'],
    timeout: 1000,
  });

  if (response.stdout) {
    return JSON.parse(response.stdout.replace(/\n/g, '')) as {
      running: number;
      enabled: number;
      status: string;
    };
  }

  return { running: 0, enabled: 0, status: 'unknown' };
}
