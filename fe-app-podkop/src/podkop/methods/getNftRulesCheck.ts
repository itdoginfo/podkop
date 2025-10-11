import { executeShellCommand } from '../../helpers';
import { Podkop } from '../types';

export async function getNftRulesCheck(): Promise<
  Podkop.MethodResponse<Podkop.NftRulesCheckResult>
> {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop',
    args: ['check_nft_rules'],
    timeout: 10000,
  });

  if (response.stdout) {
    return {
      success: true,
      data: JSON.parse(response.stdout) as Podkop.NftRulesCheckResult,
    };
  }

  return {
    success: false,
    error: '',
  };
}
