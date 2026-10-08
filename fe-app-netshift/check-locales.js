#!/usr/bin/env node
// Fails when a translation is missing, or when the catalogue that the LuCI package
// compiles has drifted away from the source of truth.
//
// Why this exists (issue #97): the other frontend gates only prove that a msgid is
// PRESENT in every locale — the .pot and the .po are generated from the source, so
// they are always in sync. Nothing checked that the translation is actually there.
// 49 of 443 Russian strings were `msgstr ""` and shipped a half-English UI: every
// option of the 0.9.10 features (Devices, Bypass sing-box, chaining, the DNS pool,
// GeoIP, the latency URL, the update time, X25519MLKEM768) was shown in English.
//
// The distributed copy matters too: luci-app-netshift/po/ru/netshift.po is what the
// package build turns into netshift.ru.lmo, so a catalogue edited in only one of the
// two places would silently ship stale strings.
//
// Usage: node check-locales.js   (no dependencies, safe to run in its own CI job)

import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const localesDir = path.join(__dirname, 'locales');
const luciPoDir = path.resolve(__dirname, '../luci-app-netshift/po');

const errors = [];

// Minimal .po reader: only the pairs this check needs (msgid/msgstr on one line,
// which is how generate-po.js writes the catalogue).
function parsePo(content) {
    const entries = new Map();
    let msgid = null;
    for (const line of content.split('\n')) {
        if (line.startsWith('msgid ')) {
            msgid = JSON.parse(line.slice(6));
        } else if (line.startsWith('msgstr ') && msgid !== null) {
            entries.set(msgid, JSON.parse(line.slice(7)));
            msgid = null;
        }
    }
    return entries;
}

async function readIfExists(file) {
    try {
        return await fs.readFile(file, 'utf8');
    } catch {
        return null;
    }
}

const callsRaw = await fs.readFile(path.join(localesDir, 'calls.json'), 'utf8');
const calls = JSON.parse(callsRaw);
const expected = calls.map(({ key }) => key);

const files = await fs.readdir(localesDir);
const poFiles = files.filter((file) => /^netshift\.[a-zA-Z_]+\.po$/.test(file)).sort();

if (poFiles.length === 0) {
    errors.push('no locales/netshift.<lang>.po found');
}

for (const file of poFiles) {
    const lang = file.match(/^netshift\.([a-zA-Z_]+)\.po$/)[1];
    const poPath = path.join(localesDir, file);
    const po = parsePo(await fs.readFile(poPath, 'utf8'));

    // 1. Every string used by the UI must be translated.
    const missing = expected.filter((key) => !po.has(key) || po.get(key).trim() === '');
    if (missing.length > 0) {
        errors.push(
            `locales/${file}: ${missing.length} untranslated string(s) of ${expected.length} — ` +
                'add the translation (or remove the string from the source):\n' +
                missing.map((key) => `    - ${key}`).join('\n'),
        );
    }

    // 2. A translation for a string that no longer exists is dead weight and hides
    //    the real count; generate-po.js drops it on the next regeneration.
    const known = new Set(expected);
    const stale = [...po.keys()].filter((key) => key !== '' && !known.has(key));
    if (stale.length > 0) {
        errors.push(
            `locales/${file}: ${stale.length} translation(s) for strings that are no longer used ` +
                `(run "yarn locales:actualize"): ${stale.join(', ')}`,
        );
    }

    // 3. The compiled catalogue must be the one that was reviewed.
    const distributed = path.join(luciPoDir, lang, 'netshift.po');
    const distributedContent = await readIfExists(distributed);
    if (distributedContent === null) {
        errors.push(`luci-app-netshift/po/${lang}/netshift.po is missing (run "yarn locales:distribute")`);
    } else if (distributedContent !== (await fs.readFile(poPath, 'utf8'))) {
        errors.push(
            `luci-app-netshift/po/${lang}/netshift.po differs from locales/${file} ` +
                '(run "yarn locales:distribute")',
        );
    }
}

// 4. The template the translators work from must be distributed as well.
const pot = await readIfExists(path.join(localesDir, 'netshift.pot'));
const distributedPot = await readIfExists(path.join(luciPoDir, 'templates', 'netshift.pot'));
if (pot === null) {
    errors.push('locales/netshift.pot is missing (run "yarn locales:generate-pot")');
} else if (distributedPot === null) {
    errors.push('luci-app-netshift/po/templates/netshift.pot is missing (run "yarn locales:distribute")');
} else if (distributedPot !== pot) {
    errors.push('luci-app-netshift/po/templates/netshift.pot differs from locales/netshift.pot');
}

if (errors.length > 0) {
    console.error('❌ Locale check failed:\n');
    for (const error of errors) {
        console.error(`  • ${error}\n`);
    }
    process.exit(1);
}

console.log(
    `✅ Locales: ${expected.length} string(s) translated in ${poFiles.length} catalogue(s), ` +
        'and the LuCI copies are in sync.',
);
