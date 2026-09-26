/**
 * @license
 * Copyright 2026 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ChildProcess, spawn } from 'node:child_process';
import { join } from 'node:path';
import { Readable, Writable } from 'node:stream';
import * as acp from '@agentclientprotocol/sdk';
import { TestRig } from './test-helper.js';

class SessionUpdateCollector implements acp.Client {
  updates: acp.SessionNotification[] = [];

  sessionUpdate = async (params: acp.SessionNotification) => {
    this.updates.push(params);
  };

  requestPermission = async (): Promise<acp.RequestPermissionResponse> => {
    throw new Error('unexpected permission request');
  };
}

describe('ACP usage reporting', () => {
  let rig: TestRig;
  let child: ChildProcess | undefined;

  beforeEach(() => {
    rig = new TestRig();
  });

  afterEach(async () => {
    child?.kill();
    child = undefined;
    await rig.cleanup();
  });

  it('returns standard usage and emits usage_update', async () => {
    rig.setup('acp-usage', {
      fakeResponsesPath: join(import.meta.dirname, 'acp-usage.responses'),
    });

    const bundlePath = join(import.meta.dirname, '..', 'bundle/gemini.js');
    child = spawn(
      'node',
      [
        bundlePath,
        '--acp',
        '--fake-responses',
        join(rig.testDir!, 'fake-responses.json'),
      ],
      {
        cwd: rig.testDir!,
        stdio: ['pipe', 'pipe', 'inherit'],
        env: {
          ...process.env,
          GEMINI_API_KEY: 'fake-key',
          GEMINI_CLI_HOME: rig.homeDir!,
        },
      },
    );

    const input = Writable.toWeb(child.stdin!);
    const output = Readable.toWeb(child.stdout!) as ReadableStream<Uint8Array>;
    const testClient = new SessionUpdateCollector();
    const stream = acp.ndJsonStream(input, output);
    const connection = new acp.ClientSideConnection(() => testClient, stream);

    await connection.initialize({
      protocolVersion: acp.PROTOCOL_VERSION,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
    });

    const { sessionId } = await connection.newSession({
      cwd: rig.testDir!,
      mcpServers: [],
    });

    const result = await connection.prompt({
      sessionId,
      prompt: [{ type: 'text', text: 'Say hello' }],
    });

    if (!result.usage) {
      throw new Error('ACP_USAGE_MISSING');
    }

    expect(result.usage).toEqual({
      totalTokens: 30,
      inputTokens: 20,
      outputTokens: 7,
      cachedReadTokens: 4,
      thoughtTokens: 3,
    });

    const usageUpdates = testClient.updates.filter(
      (notification) => notification.update.sessionUpdate === 'usage_update',
    );
    expect(usageUpdates).toHaveLength(1);
    expect(usageUpdates[0]?.update).toEqual({
      sessionUpdate: 'usage_update',
      used: 27,
      size: 1_048_576,
    });
  }, 30000);
});
