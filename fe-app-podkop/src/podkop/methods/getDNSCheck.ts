import { executeShellCommand } from '../../helpers';
import { Podkop } from '../types';

export async function getDNSCheck(): Promise<
  Podkop.MethodResponse<Podkop.DnsCheckResult>
> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['check_dns_available'],
    timeout: 10000,
  });

  if (response.stdout) {
    return {
      success: true,
      data: JSON.parse(response.stdout) as Podkop.DnsCheckResult,
    };
  }

  return {
    success: false,
    error: '',
  };
}
