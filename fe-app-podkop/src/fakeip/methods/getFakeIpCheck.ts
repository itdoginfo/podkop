import { createBaseApiRequest, IBaseApiResponse } from '../../api';
import { FAKEIP_CHECK_DOMAIN } from '../../constants';

interface IGetFakeIpCheckResponse {
  fakeip: boolean;
  IP: string;
}

export async function getFakeIpCheck(): Promise<
  IBaseApiResponse<IGetFakeIpCheckResponse>
> {
  return createBaseApiRequest<IGetFakeIpCheckResponse>(
    () =>
      fetch(`https://${FAKEIP_CHECK_DOMAIN}/check`, {
        method: 'GET',
        headers: { 'Content-Type': 'application/json' },
      }),
    {
      operationName: 'getFakeIpCheck',
      timeoutMs: 5000,
    },
  );
}
