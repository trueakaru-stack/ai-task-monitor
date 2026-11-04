import { publish } from '../app/integrations/provider-transport.mjs';

const pipeName = process.argv[2];
if (!pipeName) process.exit(2);
const acknowledged = [];
let failures = 0;
let reportedGaps = 0;
for (let index = 0; index < 60; index += 1) {
  const session = `burst_${index}`;
  const event = { version: 1, provider: 'opencode', session, kind: 'active' };
  if (await publish(event, { pipeName })) {
    acknowledged.push(session);
  } else {
    failures += 1;
    for (let attempt = 0; attempt < 5; attempt += 1) {
      if (await publish({ ...event, kind: 'gap' }, { pipeName })) { reportedGaps += 1; break; }
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
}
process.stdout.write(JSON.stringify({ acknowledged, failures, reportedGaps }));
