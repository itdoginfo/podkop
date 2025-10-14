import { ClashAPI } from '../../types';
import { getClashApiUrl } from '../../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

export async function getProxies(): Promise<
  IBaseApiResponse<ClashAPI.Proxies>
> {
  return createBaseApiRequest<ClashAPI.Proxies>(() =>
    fetch(`${getClashApiUrl()}/proxies`, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
