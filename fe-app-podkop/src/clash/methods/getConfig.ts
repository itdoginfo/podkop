import { ClashAPI } from '../types';
import { getClashApiUrl } from '../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

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
