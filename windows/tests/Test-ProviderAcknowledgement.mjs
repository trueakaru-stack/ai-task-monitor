import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import net from 'node:net';
import { publish } from '../app/integrations/provider-transport.mjs';

if (process.platform === 'win32') {
  async function run(reply) {
    const name = `AITaskMonitor.Test.Ack${randomUUID().replaceAll('-', '')}`;
    const sockets = new Set();
    const server = net.createServer(socket => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
      socket.once('data', () => {
        if (reply === 'missing') socket.destroy();
        else if (reply === 'valid') socket.write(Buffer.from([0x06]));
        else if (reply === 'invalid') socket.write(Buffer.from([0x15]));
      });
    });
    await new Promise((resolve, reject) => server.once('error', reject).listen(`\\\\.\\pipe\\${name}`, resolve));
    try {
      return await publish({ version: 1, provider: 'opencode', session: 'fixture', kind: 'active' }, { pipeName: name, timeoutMs: 100 });
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    }
  }
  assert.equal(await run('valid'), true);
  assert.equal(await run('missing'), false);
  assert.equal(await run('invalid'), false);
  assert.equal(await run('timeout'), false);
  console.log('Provider transport: acknowledgement, missing reply, invalid reply and timeout verified.');
} else console.log('Windows named-pipe acknowledgement fixture skipped on this platform.');
