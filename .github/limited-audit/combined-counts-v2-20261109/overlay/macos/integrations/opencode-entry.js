// OpenCode 1.18.29+ calls server(); OpenCode 2 calls setup().
// The support modules live outside the auto-discovered plugin directory.
import { createOpenCodeObserver, observeOpenCodeV2, observeOpenCodeV2Restartable } from '../ai-task-monitor-data/provider-observers.mjs';
import { createRestartableSender, loadV2Startup } from '../ai-task-monitor-data/provider-v2-sender.mjs';

export default {
  id: 'ai-task-monitor',
  async server() { return createOpenCodeObserver(); },
  setup(ctx) {
    try {
      const directory = typeof process.getuid === 'function' ? `/private/tmp/aitm-provider-${process.getuid()}` : '';
      const startup = loadV2Startup('opencode', 'global', directory);
      if (startup) {
        const sender = createRestartableSender({ provider: 'opencode', scope: 'global', ...startup });
        if (sender) {
          const stop = observeOpenCodeV2Restartable(ctx, sender);
          return () => { stop(); sender.close(); };
        }
      }
    } catch { /* The existing v1 observer remains available. */ }
    return observeOpenCodeV2(ctx);
  },
};
