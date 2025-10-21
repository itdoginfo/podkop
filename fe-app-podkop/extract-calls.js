import fg from 'fast-glob';
import fs from 'fs/promises';
import path from 'path';

const outputFile = 'locales/calls.json';

const tsSearchGlob = 'src/**/*.ts';
const jsSearchGlob = '../luci-app-podkop/htdocs/luci-static/resources/view/podkop/**/*.js';

function extractAllUnderscoreCallsFromContent(content) {
    const results = [];
    let index = 0;

    while (index < content.length) {
        const start = content.indexOf('_(', index);
        if (start === -1) break;

        let i = start + 2;
        let depth = 1;

        while (i < content.length && depth > 0) {
            if (content[i] === '(') depth++;
            else if (content[i] === ')') depth--;
            i++;
        }

        const raw = content.slice(start, i);
        results.push({ raw, index: start });
        index = i;
    }

    return results;
}

function getLineNumber(content, charIndex) {
    return content.slice(0, charIndex).split('\n').length;
}

function extractKey(call) {
    const match = call.match(/^_\(\s*(['"`])((?:\\\1|.)*?)\1\s*\)$/);
    return match ? match[2].trim() : null;
}

function normalizeCall(call) {
    return call
        .replace(/\s*\n\s*/g, ' ')
        .replace(/\s+/g, ' ')
        .replace(/\(\s+/g, '(')
        .replace(/\s+\)/g, ')')
        .replace(/,\s*\)$/, ')')
        .trim();
}

async function extractAllUnderscoreCallsWithLocations() {
    const files = [
        ...(await fg(tsSearchGlob, { ignore: ['**/*test.ts'], absolute: true })),
        ...(await fg(jsSearchGlob, { ignore: ['**/main.js'], absolute: true })),
    ];

    const callMap = new Map();

    for (const file of files) {
        const content = await fs.readFile(file, 'utf8');
        const relativePath = path.relative(process.cwd(), file);
        const extracted = extractAllUnderscoreCallsFromContent(content);

        for (const { raw, index } of extracted) {
            const line = getLineNumber(content, index);
            const location = `${relativePath}:${line}`;

            const normalized = normalizeCall(raw);
            const key = extractKey(normalized);

            if (!callMap.has(normalized)) {
                callMap.set(normalized, {
                    call: normalized,
                    key: key ?? '',
                    places: [],
                });
            }

            callMap.get(normalized).places.push(location);
        }
    }

    const result = [...callMap.values()];
    await fs.mkdir(path.dirname(outputFile), { recursive: true });
    await fs.writeFile(outputFile, JSON.stringify(result, null, 2), 'utf8');

    console.log(`✅ Найдено ${result.length} уникальных вызовов _(...). Сохранено в ${outputFile}`);
}

extractAllUnderscoreCallsWithLocations().catch(console.error);
