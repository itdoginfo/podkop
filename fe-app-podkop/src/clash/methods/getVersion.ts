import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';
import { getClashApiUrl } from '../../helpers';

export async function getClashVersion(): Promise<
  IBaseApiResponse<ClashAPI.Version>
> {
  return createBaseApiRequest<ClashAPI.Version>(() =>
    fetch(`${getClashApiUrl()}/version`, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
