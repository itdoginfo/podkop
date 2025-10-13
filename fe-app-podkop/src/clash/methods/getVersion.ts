import { ClashAPI } from '../types';
import { getClashApiUrl } from '../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

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
