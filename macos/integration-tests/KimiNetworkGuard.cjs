// Loaded only by the disposable Kimi approval fixture. Block outside networks.
const net = require('node:net');
const dns = require('node:dns');
const crypto = require('node:crypto');
const expected = 'AITaskMonitor.ProviderEvents.' +
  crypto.createHash('sha256').update(process.env.USERPROFILE || '').digest('hex').slice(0, 24);
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  const options = first && typeof first === 'object' ? first :
    typeof first === 'number' ? { port: first, host: typeof args[1] === 'string' ? args[1] : '127.0.0.1' } : { path: first };
  if (options.path) {
    const syntheticPipe = `\\\\.\\pipe\\${expected}`;
    if (options.path !== syntheticPipe && !String(options.path).startsWith(`${process.env.AITM_FIXTURE_ROOT}/`)) {
      throw new Error('fixture-network-denied');
    }
  } else if (!['127.0.0.1', '::1', 'localhost'].includes(options.host ?? '127.0.0.1')) {
    throw new Error('fixture-network-denied');
  }
  return connect.apply(this, args);
};
const lookup = dns.lookup;
dns.lookup = function (host, ...args) {
  if (!['127.0.0.1', '::1', 'localhost'].includes(host)) throw new Error('fixture-dns-denied');
  return lookup.call(this, host, ...args);
};
