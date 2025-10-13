import { createBaseApiRequest, IBaseApiResponse } from '../../api';
import { IP_CHECK_DOMAIN } from '../../constants';

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
