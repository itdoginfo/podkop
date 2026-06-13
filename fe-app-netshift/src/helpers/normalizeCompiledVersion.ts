export function normalizeCompiledVersion(version: string) {
  if (version.includes('COMPILED')) {
    return 'dev';
  }

  return version;
}
