import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';
import { getClashApiUrl } from '../../helpers';

export async function getClashConfig(): Promise<
  IBaseApiResponse<ClashAPI.Config>
> {
  return createBaseApiRequest<ClashAPI.Config>(() =>
    fetch(`${getClashApiUrl()}/configs`, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
