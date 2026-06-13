import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const sourceDir = path.resolve(__dirname, 'locales');
const targetRoot = path.resolve(__dirname, '../luci-app-netshift/po');

async function main() {
    const files = await fs.readdir(sourceDir);

    for (const file of files) {
        const filePath = path.join(sourceDir, file);

        if (file === 'netshift.pot') {
            const potTarget = path.join(targetRoot, 'templates', 'netshift.pot');
            await fs.mkdir(path.dirname(potTarget), { recursive: true });
            await fs.copyFile(filePath, potTarget);
            console.log(`✅ Copied POT: ${filePath} → ${potTarget}`);
        }

        const match = file.match(/^netshift\.([a-zA-Z_]+)\.po$/);
        if (match) {
            const lang = match[1];
            const poTarget = path.join(targetRoot, lang, 'netshift.po');
            await fs.mkdir(path.dirname(poTarget), { recursive: true });
            await fs.copyFile(filePath, poTarget);
            console.log(`✅ Copied ${lang.toUpperCase()}: ${filePath} → ${poTarget}`);
        }
    }
}

main().catch((err) => {
    console.error('❌ Ошибка при распространении переводов:', err);
    process.exit(1);
});
