import { executeShellCommand } from '../../../helpers';
import { Podkop } from '../../types';

export async function callBaseMethod<T>(
  method: Podkop.AvailableMethods,
  args: string[] = [],
): Promise<Podkop.MethodResponse<T>> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: [method as string, ...args],
    timeout: 10000,
  });

  if (response.stdout) {
    return {
      success: true,
      data: JSON.parse(response.stdout) as T,
    };
  }

  return {
    success: false,
    error: '',
  };
}
