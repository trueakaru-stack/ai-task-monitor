// Test-only child: no agents, profiles, sockets, or network.
const before = process.hrtime.bigint();
const uptime = process.uptime();
const after = process.hrtime.bigint();
process.stdout.write(JSON.stringify({
  runtime: process.versions.bun ? 'bun' : 'node',
  version: process.versions.bun || process.versions.node,
  libuv: process.versions.uv || null,
  before: before.toString(),
  after: after.toString(),
  uptime,
}) + '\n');
