import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';
import { getClashApiUrl } from '../../helpers';

export async function getClashGroupDelay(
  group: string,
  url = 'https://www.gstatic.com/generate_204',
  timeout = 2000,
): Promise<IBaseApiResponse<ClashAPI.Delays>> {
  const endpoint = `${getClashApiUrl()}/group/${group}/delay?url=${encodeURIComponent(
    url,
  )}&timeout=${timeout}`;

  return createBaseApiRequest<ClashAPI.Delays>(() =>
    fetch(endpoint, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
