import { getClashApiUrl } from '../../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

export async function getGroupLatency(
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
