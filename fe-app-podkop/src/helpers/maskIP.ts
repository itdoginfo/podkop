export function maskIP(ip: string = ''): string {
  const ipv4Regex = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

  return ip.replace(ipv4Regex, (_match, _p1, _p2, _p3, p4) => `XX.XX.XX.${p4}`);
}
