// Inline Markdown of release notes: [text](https://...) links, **bold**, `code`. Pure, so it
// can be tested; the caller builds the DOM (everything goes in as text, never as HTML).
export type ChangelogToken =
  | { kind: 'text'; text: string }
  | { kind: 'link'; text: string; href: string }
  | { kind: 'bold'; text: string }
  | { kind: 'code'; text: string };

const INLINE =
  /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)|\*\*([^*]+)\*\*|`([^`]+)`/g;

export function tokenizeInline(line: string): ChangelogToken[] {
  const tokens: ChangelogToken[] = [];
  let last = 0;

  for (const match of line.matchAll(INLINE)) {
    const index = match.index ?? 0;

    if (index > last) {
      tokens.push({ kind: 'text', text: line.slice(last, index) });
    }

    if (match[1] !== undefined) {
      tokens.push({ kind: 'link', text: match[1], href: match[2] });
    } else if (match[3] !== undefined) {
      tokens.push({ kind: 'bold', text: match[3] });
    } else {
      tokens.push({ kind: 'code', text: match[4] });
    }

    last = index + match[0].length;
  }

  if (last < line.length) {
    tokens.push({ kind: 'text', text: line.slice(last) });
  }

  return tokens;
}
