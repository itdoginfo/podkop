import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';

export async function getClashConfig(): Promise<
  IBaseApiResponse<ClashAPI.Config>
> {
  return createBaseApiRequest<ClashAPI.Config>(() =>
    fetch('http://192.168.160.129:9090/configs', {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
