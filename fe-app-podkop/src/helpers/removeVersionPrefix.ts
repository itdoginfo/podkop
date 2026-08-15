export function removeVersionPrefix(version: string) {
  return version.replace(/^v/, '');
}
