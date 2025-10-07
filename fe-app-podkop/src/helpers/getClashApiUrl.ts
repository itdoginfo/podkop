export function getClashApiUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}
