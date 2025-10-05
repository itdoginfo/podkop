import { ClashAPI, IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';

export async function getClashGroupDelay(
  group: string,
  url = 'https://www.gstatic.com/generate_204',
  timeout = 2000,
): Promise<IBaseApiResponse<ClashAPI.Delays>> {
  const endpoint = `http://192.168.160.129:9090/group/${group}/delay?url=${encodeURIComponent(
    url,
  )}&timeout=${timeout}`;

  return createBaseApiRequest<ClashAPI.Delays>(() =>
    fetch(endpoint, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    }),
  );
}
