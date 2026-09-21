#!/usr/bin/env bash
set -euo pipefail

node --version
npm --version

echo 'Installing exact lockfile dependencies for SessionEnd idempotence validation'
npm ci

echo 'Building all workspaces before targeted validation'
npm run build

echo 'Installing temporary regression test against the immutable candidate'
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

echo 'Running committed regression test when present on the candidate'
if [[ -f packages/core/src/hooks/hookSystem.sessionEnd.test.ts ]]; then
  npm test -w @google/gemini-cli-core -- src/hooks/hookSystem.sessionEnd.test.ts
fi

echo 'Running existing HookSystem integration coverage'
npm test -w @google/gemini-cli-core -- src/hooks/hookSystem.test.ts

echo 'Running full repository preflight on the exact candidate'
npm run preflight
