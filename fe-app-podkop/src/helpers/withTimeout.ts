export async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  operationName: string,
  timeoutMessage = _('Operation timed out'),
): Promise<T> {
  let timeoutId;
  const start = performance.now();

  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error(timeoutMessage)), timeoutMs);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    clearTimeout(timeoutId);
    const elapsed = performance.now() - start;
    console.log(`[${operationName}] Execution time: ${elapsed.toFixed(2)} ms`);
  }
}
