import { executeShellCommand } from '../../helpers';
import { Podkop } from '../types';

export async function getSingBoxCheck(): Promise<
  Podkop.MethodResponse<Podkop.SingBoxCheckResult>
> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['check_sing_box'],
    timeout: 10000,
  });

  if (response.stdout) {
    return {
      success: true,
      data: JSON.parse(response.stdout) as Podkop.SingBoxCheckResult,
    };
  }

  return {
    success: false,
    error: '',
  };
}
