export function splitProxyString(str: string) {
  return str
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => !line.startsWith('//'))
    .filter(Boolean);
}
