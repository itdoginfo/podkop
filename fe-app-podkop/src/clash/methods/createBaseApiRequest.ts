import { IBaseApiResponse } from '../types';

export async function createBaseApiRequest<T>(
  fetchFn: () => Promise<Response>,
): Promise<IBaseApiResponse<T>> {
  try {
    const response = await fetchFn();

    if (!response.ok) {
      return {
        success: false as const,
        message: `${_('HTTP error')} ${response.status}: ${response.statusText}`,
      };
    }

    const data: T = await response.json();

    return {
      success: true as const,
      data,
    };
  } catch (e) {
    return {
      success: false as const,
      message: e instanceof Error ? e.message : _('Unknown error'),
    };
  }
}
