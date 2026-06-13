import { IP_CHECK_DOMAIN } from '../../../constants';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

interface IGetIpCheckResponse {
  fakeip: boolean;
  IP: string;
}

export async function getIpCheck(): Promise<
  IBaseApiResponse<IGetIpCheckResponse>
> {
  return createBaseApiRequest<IGetIpCheckResponse>(
    () =>
      fetch(`https://${IP_CHECK_DOMAIN}/check`, {
        method: 'GET',
        headers: { 'Content-Type': 'application/json' },
      }),
    {
      operationName: 'getIpCheck',
      timeoutMs: 5000,
    },
  );
}
