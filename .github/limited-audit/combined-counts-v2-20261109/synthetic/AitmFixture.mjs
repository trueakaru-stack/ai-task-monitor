// Test-only fixture. A fresh directory / named pipe is owned by this process.
import { createHash } from 'node:crypto';
import { lstat, mkdtemp, realpath, rmdir, unlink } from 'node:fs/promises';
import net from 'node:net';

const pattern = /^\/private\/tmp\/aitm-provider-fixture-[A-Za-z0-9]+$/;

export async function isolatedDirectory() {
  if (process.platform !== 'darwin') return { path: null, close: async () => {} };
  const path = await mkdtemp('/private/tmp/aitm-provider-fixture-');
  const info = await lstat(path);
  if (!pattern.test(path) || await realpath(path) !== path || !info.isDirectory() ||
      info.uid !== process.getuid() || (info.mode & 0o077) !== 0) throw Error('Unsafe test directory.');
  return { path, close: async () => {
    if (!pattern.test(path) || await realpath(path) !== path) throw Error('Unsafe test cleanup.');
    await rmdir(path);
  } };
}

export async function isolatedListener(profile) {
  const directory = await isolatedDirectory();
  const digest = createHash('sha256').update(profile, 'utf8').digest('hex').slice(0, 24);
  const target = process.platform === 'win32' ? `\\\\.\\pipe\\AITaskMonitor.ProviderEvents.${digest}` :
    directory.path ? `${directory.path}/events.sock` : null;
  if (!target) throw Error('No supported synthetic IPC transport.');
  let resolveEvent, rejectEvent, count = 0, checked = false;
  const event = new Promise((resolve, reject) => { resolveEvent = resolve; rejectEvent = reject; });
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    let frame = Buffer.alloc(0), consumed = false;
    socket.on('error', rejectEvent);
    socket.on('data', chunk => {
      if (consumed) { rejectEvent(Error('Extra IPC frame.')); return; }
      frame = Buffer.concat([frame, chunk]);
      if (frame.length < 4) return;
      const size = frame.readUInt32LE(0);
      if (size < 2 || size > 65536 || frame.length > size + 4) { rejectEvent(Error('Invalid IPC frame.')); return; }
      if (frame.length < size + 4) return;
      try {
        const value = JSON.parse(frame.subarray(4).toString('utf8'));
        consumed = true;
        if (++count !== 1) throw Error('Multiple IPC events.');
        socket.end(Buffer.from([0x06]));
        resolveEvent(value);
      } catch (error) { rejectEvent(error); }
    });
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(target, resolve); });
  } catch (error) { await directory.close(); throw error; }
  return { directory: directory.path,
    received: async () => {
      let timer;
      try { const value = await Promise.race([event, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Error('No synthetic event received.')), 2000);
      })]); checked = true; return value; } finally { clearTimeout(timer); }
    },
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      if (directory.path) {
        try { await unlink(target); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        await directory.close();
      }
      if (checked && count !== 1) throw Error('Expected exactly one synthetic event.');
    }
  };
}
