import 'dotenv/config';
import chokidar from 'chokidar';
import SFTPClient from 'ssh2-sftp-client';
import path from 'path';
import fs from 'fs';
import { glob } from 'glob';

const sftp = new SFTPClient();

const config = {
  host: process.env.SFTP_HOST,
  port: Number(process.env.SFTP_PORT || 22),
  username: process.env.SFTP_USER,
  ...(process.env.SFTP_PRIVATE_KEY
      ? { privateKey: fs.readFileSync(process.env.SFTP_PRIVATE_KEY) }
      : { password: process.env.SFTP_PASS }),
};

const syncDirs = [
  {
    local: path.resolve(process.env.LOCAL_DIR_FE ?? '../luci-app-netshift/htdocs/luci-static/resources/view/netshift'),
    remote: process.env.REMOTE_DIR_FE ?? '/www/luci-static/resources/view/netshift',
  },
  {
    local: path.resolve(process.env.LOCAL_DIR_BIN ?? '../netshift/files/usr/bin/'),
    remote: process.env.REMOTE_DIR_BIN ?? '/usr/bin/',
  },
  {
    local: path.resolve(process.env.LOCAL_DIR_LIB ?? '../netshift/files/usr/lib/'),
    remote: process.env.REMOTE_DIR_LIB ?? '/usr/lib/netshift/',
  },
  {
    local: path.resolve(process.env.LOCAL_DIR_INIT ?? '../netshift/files/etc/init.d/'),
    remote: process.env.REMOTE_DIR_INIT ?? '/etc/init.d/',
  }
];

async function uploadFile(filePath, baseDir, remoteBase) {
  const relativePath = path.relative(baseDir, filePath);
  const remotePath = path.posix.join(remoteBase, relativePath);

  console.log(`↑ Uploading: ${relativePath} -> ${remotePath}`);
  try {
    await sftp.fastPut(filePath, remotePath);
    console.log(`✓ Uploaded: ${relativePath}`);
  } catch (err) {
    console.error(`✗ Failed: ${relativePath}: ${err.message}`);
  }
}

async function deleteFile(filePath, baseDir, remoteBase) {
  const relativePath = path.relative(baseDir, filePath);
  const remotePath = path.posix.join(remoteBase, relativePath);

  console.log(`⨯ Removing: ${relativePath}`);
  try {
    await sftp.delete(remotePath);
    console.log(`✓ Removed: ${relativePath}`);
  } catch (err) {
    console.warn(`⚠ Could not delete ${relativePath}: ${err.message}`);
  }
}

async function uploadAllFiles() {
  for (const { local, remote } of syncDirs) {
    console.log(`📂 Uploading all from ${local}`);
    const files = await glob(`${local}/**/*`, { nodir: true });
    for (const file of files) {
      await uploadFile(file, local, remote);
    }
  }
  console.log('✅ Initial upload complete!');
}

async function main() {
  await sftp.connect(config);
  console.log(`🔌 Connected to ${config.host}`);

  await uploadAllFiles();

  for (const { local, remote } of syncDirs) {
    chokidar.watch(local, { ignoreInitial: true }).on('all', async (event, filePath) => {
      if (event === 'add' || event === 'change') {
        await uploadFile(filePath, local, remote);
      } else if (event === 'unlink') {
        await deleteFile(filePath, local, remote);
      }
    });
  }

  process.on('SIGINT', async () => {
    console.log('👋 Disconnecting...');
    await sftp.end();
    process.exit();
  });
}

main().catch((err) => {
  console.error('💥 Fatal:', err);
});
