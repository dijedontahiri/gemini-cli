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
    sessionId: 'session-end-test',
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

describe('HookSystem SessionEnd lifecycle', () => {
  it('fires SessionEnd only once for duplicate end requests in one session', async () => {
    const hookSystem = createHookSystem();
    const eventHandler = hookSystem.getEventHandler();
    const fireSessionEndEvent = vi
      .spyOn(eventHandler, 'fireSessionEndEvent')
      .mockResolvedValue(undefined as never);

    await hookSystem.fireSessionEndEvent(SessionEndReason.Exit);
    await hookSystem.fireSessionEndEvent(SessionEndReason.Exit);

    expect(fireSessionEndEvent).toHaveBeenCalledTimes(1);
    expect(fireSessionEndEvent).toHaveBeenCalledWith(SessionEndReason.Exit);
  });

  it('allows SessionEnd again after a new session starts', async () => {
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
    expect(fireSessionEndEvent).toHaveBeenNthCalledWith(
      1,
      SessionEndReason.Clear,
    );
    expect(fireSessionEndEvent).toHaveBeenNthCalledWith(
      2,
      SessionEndReason.Exit,
    );
  });

  it('allows a SessionEnd retry when the first attempt rejects', async () => {
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
