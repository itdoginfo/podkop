export function parseQueryString(query: string): Record<string, string> {
  const clean = query.startsWith('?') ? query.slice(1) : query;

  return clean
    .split('&')
    .filter(Boolean)
    .reduce(
      (acc, pair) => {
        const [rawKey, rawValue = ''] = pair.split('=');

        if (!rawKey) {
          return acc;
        }

        const key = decodeURIComponent(rawKey);
        const value = decodeURIComponent(rawValue);

        return { ...acc, [key]: value };
      },
      {} as Record<string, string>,
    );
}
