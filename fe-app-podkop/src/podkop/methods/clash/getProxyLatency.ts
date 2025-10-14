import { getClashApiUrl } from '../../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

export async function getProxyLatency(
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
