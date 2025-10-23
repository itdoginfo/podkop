import fs from 'fs/promises';
import path from 'path';
import glob from 'fast-glob';
import { parse } from '@babel/parser';
import traverse from '@babel/traverse';
import * as t from '@babel/types';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function stripIllegalReturn(code) {
    return code.replace(/^\s*return\s+[^;]+;\s*$/gm, (match, offset, input) => {
        const after = input.slice(offset + match.length).trim();
        return after === '' ? '' : match;
    });
}

const files = await glob([
    'src/**/*.ts',
    '../luci-app-podkop/htdocs/luci-static/resources/view/podkop/**/*.js',
], {
    ignore: [
        '**/*.test.ts',
        '**/main.js',
        '../luci-app-podkop/htdocs/luci-static/resources/view/podkop/main.js',
    ],
    absolute: true,
});

const results = {};

for (const file of files) {
    const contentRaw = await fs.readFile(file, 'utf8');
    const content = stripIllegalReturn(contentRaw);
    const relativePath = path.relative(process.cwd(), file);

    let ast;
    try {
        ast = parse(content, {
            sourceType: 'module',
            plugins: file.endsWith('.ts') ? ['typescript'] : [],
        });
    } catch (e) {
        console.warn(`⚠️ Parse error in ${relativePath}, skipping`);
        continue;
    }

    traverse.default(ast, {
        CallExpression(path) {
            if (t.isIdentifier(path.node.callee, { name: '_' })) {
                const arg = path.node.arguments[0];
                if (t.isStringLiteral(arg)) {
                    const key = arg.value.trim();
                    if (!key) return; // ❌ пропустить пустые ключи
                    const location = `${relativePath}:${path.node.loc?.start.line ?? '?'}`;

                    if (!results[key]) {
                        results[key] = { call: key, key, places: [] };
                    }

                    results[key].places.push(location);
                }
            }
        },
    });
}

const outFile = 'locales/calls.json';
const sorted = Object.values(results).sort((a, b) => a.key.localeCompare(b.key)); // 🔤 сортировка по ключу

await fs.mkdir(path.dirname(outFile), { recursive: true });
await fs.writeFile(outFile, JSON.stringify(sorted, null, 2), 'utf8');
console.log(`✅ Extracted ${sorted.length} translations to ${outFile}`);
