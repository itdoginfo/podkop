import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';
import { getClashApiUrl } from '../../helpers';

export async function getClashProxies(): Promise<
  IBaseApiResponse<ClashAPI.Proxies>
> {
  return createBaseApiRequest<ClashAPI.Proxies>(() =>
    fetch(`${getClashApiUrl()}/proxies`, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
