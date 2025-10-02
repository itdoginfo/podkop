export function getBaseUrl(): string {
  const { protocol, hostname } = window.location;
  return `${protocol}//${hostname}`;
}
