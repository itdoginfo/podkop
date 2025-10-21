import fs from 'fs/promises';
import { execSync } from 'child_process';

const inputFile = 'locales/calls.json';
const outputFile = 'locales/podkop.pot';
const projectId = 'PODKOP';

function getGitUser() {
    const name = execSync('git config user.name').toString().trim();
    const email = execSync('git config user.email').toString().trim();
    return { name, email };
}

function getPotHeader({ name, email }) {
    const now = new Date();
    const date = now.toISOString().replace('T', ' ').slice(0, 16);
    const offset = -now.getTimezoneOffset();
    const sign = offset >= 0 ? '+' : '-';
    const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0');
    const minutes = String(Math.abs(offset) % 60).padStart(2, '0');
    const timezone = `${sign}${hours}${minutes}`;

    return [
        '# SOME DESCRIPTIVE TITLE.',
        `# Copyright (C) ${now.getFullYear()} THE PACKAGE'S COPYRIGHT HOLDER`,
        `# This file is distributed under the same license as the ${projectId} package.`,
        `# ${name} <${email}>, ${now.getFullYear()}.`,
        '#, fuzzy',
        'msgid ""',
        'msgstr ""',
        `"Project-Id-Version: ${projectId}\\n"`,
        `"Report-Msgid-Bugs-To: \\n"`,
        `"POT-Creation-Date: ${date}${timezone}\\n"`,
        `"PO-Revision-Date: ${date}${timezone}\\n"`,
        `"Last-Translator: ${name} <${email}>\\n"`,
        `"Language-Team: LANGUAGE <LL@li.org>\\n"`,
        `"Language: \\n"`,
        `"MIME-Version: 1.0\\n"`,
        `"Content-Type: text/plain; charset=UTF-8\\n"`,
        `"Content-Transfer-Encoding: 8bit\\n"`,
        '',
    ].join('\n');
}

function escapePoString(str) {
    return str.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function generateEntry(item) {
    const locations = item.places.map(loc => `#: ${loc}`).join('\n');
    const msgid = escapePoString(item.key);
    return [
        locations,
        `msgid "${msgid}"`,
        `msgstr ""`,
        ''
    ].join('\n');
}

async function generatePot() {
    const gitUser = getGitUser();
    const raw = await fs.readFile(inputFile, 'utf8');
    const entries = JSON.parse(raw);

    const header = getPotHeader(gitUser);
    const body = entries.map(generateEntry).join('\n');

    await fs.writeFile(outputFile, `${header}\n${body}`, 'utf8');

    console.log(`✅ POT-файл успешно создан: ${outputFile}`);
}

generatePot().catch(console.error);
