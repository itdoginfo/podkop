export function getProxyUrlName(url: string) {
  try {
    const [_link, hash] = url.split('#');

    if (!hash) {
      return '';
    }

    return decodeURIComponent(hash);
  } catch {
    return '';
  }
}
