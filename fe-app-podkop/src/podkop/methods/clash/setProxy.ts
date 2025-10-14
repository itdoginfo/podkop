import { getClashApiUrl } from '../../../helpers';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

export async function setProxy(
  selector: string,
  outbound: string,
): Promise<IBaseApiResponse<void>> {
  return createBaseApiRequest<void>(() =>
    fetch(`${getClashApiUrl()}/proxies/${selector}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: outbound }),
    }),
  );
}
