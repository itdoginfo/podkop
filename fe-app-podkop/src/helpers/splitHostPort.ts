/**
 * Splits the "host:port" part of a URL.
 *
 * A plain `split(':')` breaks on IPv6 literals, which carry colons of their own
 * and are therefore wrapped in brackets: `[2001:db8::1]:443`. Brackets are
 * stripped from the returned host, so the result is ready to be validated or
 * passed on as a bare address.
 *
 * The port is returned as-is, without being parsed or validated — callers may
 * still need to strip a trailing query or fragment from it.
 */
export function splitHostPort(hostPort: string): [string, string | undefined] {
  if (hostPort.startsWith('[')) {
    const close = hostPort.indexOf(']');

    if (close > 0) {
      const rest = hostPort.slice(close + 1);

      return [
        hostPort.slice(1, close),
        rest.startsWith(':') ? rest.slice(1) : undefined,
      ];
    }
  }

  const [host, port] = hostPort.split(':');

  return [host, port];
}
