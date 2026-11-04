// OpenCode 1.18.29+ calls server(); OpenCode 2 calls setup().
// The support modules live outside the auto-discovered plugin directory.
import { createOpenCodeObserver, observeOpenCodeV2 } from '../ai-task-monitor-data/provider-observers.mjs';

export default {
  id: 'ai-task-monitor',
  async server() { return createOpenCodeObserver(); },
  setup(ctx) { return observeOpenCodeV2(ctx); },
};
