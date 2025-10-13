import { executeShellCommand } from '../../helpers';
import { Podkop } from '../types';

export async function getFakeIPCheck(): Promise<
  Podkop.MethodResponse<Podkop.FakeIPCheckResult>
> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['check_fakeip'],
    timeout: 10000,
  });

  if (response.stdout) {
    return {
      success: true,
      data: JSON.parse(response.stdout) as Podkop.FakeIPCheckResult,
    };
  }

  return {
    success: false,
    error: '',
  };
}
