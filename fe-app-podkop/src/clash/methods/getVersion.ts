import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';

export async function getClashVersion(): Promise<
  IBaseApiResponse<ClashAPI.Version>
> {
  return createBaseApiRequest<ClashAPI.Version>(() =>
    fetch('http://192.168.160.129:9090/version', {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
