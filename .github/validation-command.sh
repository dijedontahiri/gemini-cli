#!/usr/bin/env bash
set -euo pipefail

mark_stage() {
  printf '%s\n' "$1" | tee /tmp/validation-stage
  printf '\n==> %s\n' "$1"
}

node --version
npm --version

mark_stage 'npm ci'
npm ci

mark_stage 'workspace build'
npm run build

mark_stage 'temporary SessionEnd baseline/candidate regression'
cat > packages/core/src/hooks/sessionEndValidation.test.ts <<'EOF'
/**
 * @license
 * Copyright 2026 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import { describe, expect, it, vi } from 'vitest';
import { Config } from '../config/config.js';
import { HookSystem } from './hookSystem.js';
import { SessionEndReason, SessionStartSource } from './types.js';

function createHookSystem() {
  const config = new Config({
    model: 'gemini-1.5-flash',
    targetDir: process.cwd(),
    sessionId: 'session-end-validation',
    debugMode: false,
    cwd: process.cwd(),
    hooks: {},
  });
  (
    config as unknown as {
      getMessageBus: () => undefined;
    }
  ).getMessageBus = () => undefined;
  return new HookSystem(config);
}

describe('SessionEnd lifecycle regression', () => {
  it('fires SessionEnd only once for duplicate end requests in one session', async () => {
    const hookSystem = createHookSystem();
    const eventHandler = hookSystem.getEventHandler();
    const fireSessionEndEvent = vi
      .spyOn(eventHandler, 'fireSessionEndEvent')
      .mockResolvedValue(undefined as never);

    await hookSystem.fireSessionEndEvent(SessionEndReason.Exit);
    await hookSystem.fireSessionEndEvent(SessionEndReason.Exit);

    expect(fireSessionEndEvent).toHaveBeenCalledTimes(1);
  });

  it('allows a new SessionEnd after the next SessionStart', async () => {
    const hookSystem = createHookSystem();
    const eventHandler = hookSystem.getEventHandler();
    const fireSessionEndEvent = vi
      .spyOn(eventHandler, 'fireSessionEndEvent')
      .mockResolvedValue(undefined as never);
    vi.spyOn(eventHandler, 'fireSessionStartEvent').mockResolvedValue({
      finalOutput: undefined,
    } as never);

    await hookSystem.fireSessionEndEvent(SessionEndReason.Clear);
    await hookSystem.fireSessionStartEvent(SessionStartSource.Clear);
    await hookSystem.fireSessionEndEvent(SessionEndReason.Exit);

    expect(fireSessionEndEvent).toHaveBeenCalledTimes(2);
  });

  it('allows retry after a SessionEnd rejection', async () => {
    const hookSystem = createHookSystem();
    const eventHandler = hookSystem.getEventHandler();
    const fireSessionEndEvent = vi
      .spyOn(eventHandler, 'fireSessionEndEvent')
      .mockRejectedValueOnce(new Error('hook failure'))
      .mockResolvedValueOnce(undefined as never);

    await expect(
      hookSystem.fireSessionEndEvent(SessionEndReason.Exit),
    ).rejects.toThrow('hook failure');
    await expect(
      hookSystem.fireSessionEndEvent(SessionEndReason.Exit),
    ).resolves.toBeUndefined();

    expect(fireSessionEndEvent).toHaveBeenCalledTimes(2);
  });
});
EOF

npm test -w @google/gemini-cli-core -- src/hooks/sessionEndValidation.test.ts
rm packages/core/src/hooks/sessionEndValidation.test.ts

if [[ -f packages/core/src/hooks/hookSystem.sessionEnd.test.ts ]]; then
  mark_stage 'committed SessionEnd regression test'
  npm test -w @google/gemini-cli-core -- src/hooks/hookSystem.sessionEnd.test.ts
fi

mark_stage 'existing HookSystem integration coverage'
npm test -w @google/gemini-cli-core -- src/hooks/hookSystem.test.ts

mark_stage 'interactive ctrl-c exit integration coverage'
RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests ctrl-c-exit.test.ts

mark_stage 'session clear lifecycle integration coverage'
RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests hooks-system.test.ts -t 'should fire SessionEnd and SessionStart hooks on /clear command'

mark_stage 'full repository preflight'
npm run preflight

mark_stage 'final tracked-tree diff check'
git diff --exit-code

mark_stage 'complete'
