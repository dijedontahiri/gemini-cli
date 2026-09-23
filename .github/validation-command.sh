#!/usr/bin/env bash
set -euo pipefail

mark_stage() {
  printf '%s\n' "$1" | tee /tmp/validation-stage
  printf '\n==> %s\n' "$1"
}

BASE_SHA="$(git rev-parse HEAD)"
EXPECTED_BASE='62364cb2000795537a6895261b37ec668e4cf527'
test "$BASE_SHA" = "$EXPECTED_BASE"
node --version
npm --version

apply_unit_test_patch() {
python3 - <<'PY'
from pathlib import Path
p = Path('packages/cli/src/acp/acpSession.test.ts')
s = p.read_text()
needle = '\n});\n'
pos = s.rfind(needle)
assert pos != -1, 'Session describe closing marker drifted'
test = r'''

  it('reports standard ACP usage and a usage_update notification', async () => {
    async function* usageStream() {
      yield {
        type: GeminiEventType.Content,
        value: 'Hello',
      } as const;
      yield {
        type: GeminiEventType.Finished,
        value: {
          reason: FinishReason.STOP,
          usageMetadata: {
            promptTokenCount: 20,
            candidatesTokenCount: 7,
            cachedContentTokenCount: 4,
            thoughtsTokenCount: 3,
            totalTokenCount: 30,
          },
        },
      } as const;
    }

    mockSendMessageStream.mockReturnValue(usageStream());

    const result = await session.prompt({
      sessionId: 'session-1',
      prompt: [{ type: 'text', text: 'Hi' }],
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
    expect(mockConnection.sessionUpdate).toHaveBeenCalledWith({
      sessionId: 'session-1',
      update: {
        sessionUpdate: 'usage_update',
        used: 27,
        size: 1_048_576,
      },
    });
  });
'''
s = s[:pos] + test + s[pos:]
p.write_text(s)
PY
}

apply_source_patch() {
python3 - <<'PY'
from pathlib import Path
p = Path('packages/cli/src/acp/acpSession.ts')
s = p.read_text()

old = """  type ResolvedAtCommandPath,
} from '@google/gemini-cli-core';
"""
new = """  type ResolvedAtCommandPath,
  tokenLimit,
} from '@google/gemini-cli-core';
"""
assert old in s, 'core import insertion point drifted'
s = s.replace(old, new, 1)

old = """    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    const modelUsageMap = new Map<string, { input: number; output: number }>();
"""
new = """    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let totalCachedReadTokens = 0;
    let totalThoughtTokens = 0;
    let totalTokens = 0;
    const modelUsageMap = new Map<string, { input: number; output: number }>();
    const buildUsage = (): acp.Usage => ({
      totalTokens,
      inputTokens: totalInputTokens,
      outputTokens: totalOutputTokens,
      cachedReadTokens: totalCachedReadTokens,
      thoughtTokens: totalThoughtTokens,
    });
"""
assert old in s, 'usage totals insertion point drifted'
s = s.replace(old, new, 1)

old = """      let turnModelId = this.context.config.getModel();
      let turnInputTokens = 0;
      let turnOutputTokens = 0;
"""
new = """      let turnModelId = this.context.config.getModel();
      let turnInputTokens = 0;
      let turnOutputTokens = 0;
      let turnCachedReadTokens = 0;
      let turnThoughtTokens = 0;
      let turnTotalTokens = 0;
"""
assert old in s, 'per-turn usage declaration point drifted'
s = s.replace(old, new, 1)

old = """            case GeminiEventType.Finished: {
              const usage = event.value.usageMetadata;
              if (usage) {
                turnInputTokens = usage.promptTokenCount ?? turnInputTokens;
                turnOutputTokens =
                  usage.candidatesTokenCount ?? turnOutputTokens;
              }
              break;
            }
"""
new = """            case GeminiEventType.Finished: {
              const usage = event.value.usageMetadata;
              if (usage) {
                turnInputTokens = usage.promptTokenCount ?? turnInputTokens;
                turnOutputTokens =
                  usage.candidatesTokenCount ?? turnOutputTokens;
                turnCachedReadTokens =
                  usage.cachedContentTokenCount ?? turnCachedReadTokens;
                turnThoughtTokens =
                  usage.thoughtsTokenCount ?? turnThoughtTokens;
                turnTotalTokens =
                  usage.totalTokenCount ??
                  turnInputTokens + turnOutputTokens + turnThoughtTokens;
              }
              break;
            }
"""
assert old in s, 'Finished usage block drifted'
s = s.replace(old, new, 1)

old = """      totalInputTokens += turnInputTokens;
      totalOutputTokens += turnOutputTokens;

      if (turnInputTokens > 0 || turnOutputTokens > 0) {
        const existing = modelUsageMap.get(turnModelId) ?? {
          input: 0,
          output: 0,
        };
        existing.input += turnInputTokens;
        existing.output += turnOutputTokens;
        modelUsageMap.set(turnModelId, existing);
      }

      if (stopReason !== 'end_turn') {
"""
new = """      totalInputTokens += turnInputTokens;
      totalOutputTokens += turnOutputTokens;
      totalCachedReadTokens += turnCachedReadTokens;
      totalThoughtTokens += turnThoughtTokens;
      totalTokens += turnTotalTokens;

      if (turnInputTokens > 0 || turnOutputTokens > 0) {
        const existing = modelUsageMap.get(turnModelId) ?? {
          input: 0,
          output: 0,
        };
        existing.input += turnInputTokens;
        existing.output += turnOutputTokens;
        modelUsageMap.set(turnModelId, existing);
      }

      if (
        turnInputTokens > 0 ||
        turnOutputTokens > 0 ||
        turnCachedReadTokens > 0 ||
        turnThoughtTokens > 0 ||
        turnTotalTokens > 0
      ) {
        await this.sendUpdate({
          sessionUpdate: 'usage_update',
          used: turnInputTokens + turnOutputTokens,
          size: tokenLimit(turnModelId),
        });
      }

      if (stopReason !== 'end_turn') {
"""
assert old in s, 'usage accumulation block drifted'
s = s.replace(old, new, 1)

old = """        return {
          stopReason: 'max_turn_requests',
          _meta: {
"""
new = """        return {
          stopReason: 'max_turn_requests',
          usage: buildUsage(),
          _meta: {
"""
assert old in s, 'max-turn return block drifted'
s = s.replace(old, new, 1)

old = """          return {
            stopReason: 'end_turn',
            _meta: {
"""
new = """          return {
            stopReason: 'end_turn',
            usage: buildUsage(),
            _meta: {
"""
assert old in s, 'graceful-error return block drifted'
s = s.replace(old, new, 1)

old = """        return {
          stopReason,
          _meta: {
"""
new = """        return {
          stopReason,
          usage: buildUsage(),
          _meta: {
"""
assert old in s, 'non-end return block drifted'
s = s.replace(old, new, 1)

old = """    return {
      stopReason: 'end_turn',
      _meta: {
"""
new = """    return {
      stopReason: 'end_turn',
      usage: buildUsage(),
      _meta: {
"""
assert old in s, 'final return block drifted'
s = s.replace(old, new, 1)

p.write_text(s)
PY
}

apply_integration_patch() {
cat > integration-tests/acp-usage.responses <<'EOF'
{"method":"generateContentStream","response":[{"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":7,"cachedContentTokenCount":4,"thoughtsTokenCount":3,"totalTokenCount":30}}]}
EOF
cat > integration-tests/acp-usage.test.ts <<'EOF'
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
EOF
}

mark_stage 'npm ci'
npm ci

mark_stage 'workspace build on exact baseline'
npm run build

mark_stage 'baseline unit regression patch'
apply_unit_test_patch

mark_stage 'prove current-main unit failure'
set +e
npm test -w @google/gemini-cli -- src/acp/acpSession.test.ts -t 'reports standard ACP usage and a usage_update notification' 2>&1 | tee /tmp/baseline-unit.log
baseline_unit_status=${PIPESTATUS[0]}
set -e
if [[ $baseline_unit_status -eq 0 ]]; then
  echo 'ERROR: baseline ACP usage unit regression unexpectedly passed'
  exit 1
fi
grep -F 'ACP_USAGE_MISSING' /tmp/baseline-unit.log >/dev/null
printf 'Verified intended ACP unit baseline failure on %s\n' "$BASE_SHA"

git reset --hard "$BASE_SHA"
git clean -fd

mark_stage 'baseline ACP integration regression patch'
apply_integration_patch

mark_stage 'prove current-main ACP integration failure'
set +e
GEMINI_API_KEY=fake-key RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests acp-usage.test.ts 2>&1 | tee /tmp/baseline-integration.log
baseline_integration_status=${PIPESTATUS[0]}
set -e
if [[ $baseline_integration_status -eq 0 ]]; then
  echo 'ERROR: baseline ACP usage integration regression unexpectedly passed'
  exit 1
fi
grep -F 'ACP_USAGE_MISSING' /tmp/baseline-integration.log >/dev/null
printf 'Verified intended ACP integration baseline failure on %s\n' "$BASE_SHA"

git reset --hard "$BASE_SHA"
git clean -fd

mark_stage 'apply ACP usage candidate and regressions'
apply_source_patch
apply_unit_test_patch
apply_integration_patch

mark_stage 'focused ACP usage unit regression'
npm test -w @google/gemini-cli -- src/acp/acpSession.test.ts -t 'reports standard ACP usage and a usage_update notification'

mark_stage 'full ACP session unit suite'
npm test -w @google/gemini-cli -- src/acp/acpSession.test.ts

mark_stage 'rebuild exact candidate bundle'
npm run build

mark_stage 'direct ACP usage integration regression'
GEMINI_API_KEY=fake-key RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests acp-usage.test.ts

mark_stage 'existing ACP telemetry integration coverage'
GEMINI_API_KEY=fake-key RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests acp-telemetry.test.ts

mark_stage 'full repository preflight'
npm run preflight

mark_stage 'final candidate diff review'
git add -N integration-tests/acp-usage.responses integration-tests/acp-usage.test.ts
git diff --check
expected=$'integration-tests/acp-usage.responses\nintegration-tests/acp-usage.test.ts\npackages/cli/src/acp/acpSession.test.ts\npackages/cli/src/acp/acpSession.ts'
actual="$(git diff --name-only | sort)"
printf 'Changed files:\n%s\n' "$actual"
test "$actual" = "$expected"
git diff -- packages/cli/src/acp/acpSession.ts packages/cli/src/acp/acpSession.test.ts integration-tests/acp-usage.test.ts integration-tests/acp-usage.responses

mark_stage 'complete'
