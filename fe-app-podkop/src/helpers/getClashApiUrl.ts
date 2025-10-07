export function getClashApiUrl(): string {
  const { protocol, hostname } = window.location;

  return `${protocol}//${hostname}:9090`;
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}
