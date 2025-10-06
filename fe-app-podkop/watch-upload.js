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

const localDir = path.resolve(process.env.LOCAL_DIR || './dist');
const remoteDir = process.env.REMOTE_DIR || '/www/luci-static/mypkg';

async function uploadFile(filePath) {
  const relativePath = path.relative(localDir, filePath);
  const remotePath = path.posix.join(remoteDir, relativePath);

  console.log(`Uploading: ${relativePath} -> ${remotePath}`);
  try {
    await sftp.fastPut(filePath, remotePath);
    console.log(`Uploaded: ${relativePath}`);
  } catch (err) {
    console.error(`Failed: ${relativePath}: ${err.message}`);
  }
}

async function deleteFile(filePath) {
  const relativePath = path.relative(localDir, filePath);
  const remotePath = path.posix.join(remoteDir, relativePath);

  console.log(`Removing: ${relativePath}`);
  try {
    await sftp.delete(remotePath);
    console.log(`Removed: ${relativePath}`);
  } catch (err) {
    console.warn(`Could not delete ${relativePath}: ${err.message}`);
  }
}

async function uploadAllFiles() {
  console.log('Uploading all files from', localDir);

  const files = await glob(`${localDir}/**/*`, { nodir: true });
  for (const file of files) {
    await uploadFile(file);
  }

  console.log('Initial upload complete!');
}

async function main() {
  await sftp.connect(config);
  console.log(`Connected to ${config.host}`);

  await uploadAllFiles();

  chokidar
      .watch(localDir, { ignoreInitial: true })
      .on('all', async (event, filePath) => {
        if (event === 'add' || event === 'change') {
          await uploadFile(filePath);
        } else if (event === 'unlink') {
          await deleteFile(filePath);
        }
      });

  process.on('SIGINT', async () => {
    console.log('Disconnecting...');
    await sftp.end();
    process.exit();
  });
}

main().catch(console.error);
