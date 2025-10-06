import { IBaseApiResponse } from '../types';
import { createBaseApiRequest } from './createBaseApiRequest';
import { getClashApiUrl } from '../../helpers';

export async function triggerLatencyGroupTest(
  tag: string,
  timeout: number = 5000,
  url: string = 'https://www.gstatic.com/generate_204',
): Promise<IBaseApiResponse<void>> {
  return createBaseApiRequest<void>(() =>
    fetch(
      `${getClashApiUrl()}/group/${tag}/delay?url=${encodeURIComponent(url)}&timeout=${timeout}`,
      {
        method: 'GET',
        headers: { 'Content-Type': 'application/json' },
      },
    ),
  );
}

export async function triggerLatencyProxyTest(
  tag: string,
  timeout: number = 2000,
  url: string = 'https://www.gstatic.com/generate_204',
): Promise<IBaseApiResponse<void>> {
  return createBaseApiRequest<void>(() =>
    fetch(
      `${getClashApiUrl()}/proxies/${tag}/delay?url=${encodeURIComponent(url)}&timeout=${timeout}`,
      {
        method: 'GET',
        headers: { 'Content-Type': 'application/json' },
      },
    ),
  );
}
