import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';

export async function getClashProxies(): Promise<
  IBaseApiResponse<ClashAPI.Proxies>
> {
  return createBaseApiRequest<ClashAPI.Proxies>(() =>
    fetch('http://192.168.160.129:9090/proxies', {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
