import { describe, expect, it } from 'vitest';
import { styles as dashboard } from '../../netshift/tabs/dashboard/styles';
import { styles as diagnostic } from '../../netshift/tabs/diagnostic/styles';
import { styles as manager } from '../../netshift/tabs/manager/styles';
import { styles as button } from '../../partials/button/styles';
import { styles as modal } from '../../partials/modal/styles';

// All the stylesheets go into one <style> element. One rule that is not closed
// swallows every rule after it: icons lose their size, buttons their look. A merge
// of two branches that both add rules at the end of a file once produced exactly that.

const SHEETS: Record<string, string> = {
  dashboard,
  diagnostic,
  manager,
  button,
  modal,
};

// Rules nest only inside an at-rule (@media, @supports, @keyframes).
function findProblem(css: string): string | null {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const stack: boolean[] = [];
  let head = '';
  let line = 1;

  for (const ch of text) {
    if (ch === '\n') line += 1;

    if (ch === '{') {
      const atRule = head.trim().startsWith('@');

      if (stack.length > 0 && !stack[stack.length - 1] && !atRule) {
        const parent = head.trim();
        return `line ${line}: "${parent}" opens inside a rule that is not closed`;
      }

      stack.push(atRule);
      head = '';
    } else if (ch === '}') {
      if (stack.length === 0) {
        return `line ${line}: a closing brace with nothing open`;
      }
      stack.pop();
      head = '';
    } else if (ch === ';') {
      head = '';
    } else {
      head += ch;
    }
  }

  return stack.length === 0 ? null : `${stack.length} rule(s) never closed`;
}

describe('stylesheets', () => {
  Object.entries(SHEETS).forEach(([name, css]) => {
    it(`${name}: every rule is closed`, () => {
      expect(findProblem(css)).toBeNull();
    });
  });

  it('catches a rule that is not closed', () => {
    const broken = `.a {\n  color: red;\n.b {\n  color: blue;\n}\n`;
    expect(findProblem(broken)).toContain('opens inside a rule');
  });

  it('allows rules inside an at-rule', () => {
    expect(
      findProblem('@media (max-width: 1px) {\n .a { color: red; }\n}'),
    ).toBeNull();
  });

  it('keeps the diagnostic route-check and snapshots rules apart', () => {
    expect(diagnostic).toContain(
      '.pdk_diagnostic-page__snapshots__list {\n    display: grid;',
    );
  });
});
