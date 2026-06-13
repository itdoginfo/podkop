import { withTimeout } from '../helpers';

export async function createBaseApiRequest<T>(
  fetchFn: () => Promise<Response>,
  options?: {
    timeoutMs?: number;
    operationName?: string;
    timeoutMessage?: string;
  },
): Promise<IBaseApiResponse<T>> {
  const wrappedFn = () =>
    options?.timeoutMs && options?.operationName
      ? withTimeout(
          fetchFn(),
          options.timeoutMs,
          options.operationName,
          options.timeoutMessage,
        )
      : fetchFn();

  try {
    const response = await wrappedFn();

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

export type IBaseApiResponse<T> =
  | {
      success: true;
      data: T;
    }
  | {
      success: false;
      message: string;
    };
