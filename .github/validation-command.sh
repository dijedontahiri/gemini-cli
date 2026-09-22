#!/usr/bin/env bash
set -euo pipefail

mark_stage() {
  printf '%s\n' "$1" | tee /tmp/validation-stage
  printf '\n==> %s\n' "$1"
}

BASE_SHA="$(git rev-parse HEAD)"
EXPECTED_BASE='d5b3e3accb26000d273abf16e0f1dd83aa5428a9'
test "$BASE_SHA" = "$EXPECTED_BASE"
node --version
npm --version

apply_unit_test_patch() {
python3 - <<'PY'
from pathlib import Path
p = Path('packages/core/src/tools/shell.test.ts')
s = p.read_text()
old = """const mockShellExecutionService = vi.hoisted(() => vi.fn());
const mockShellBackground = vi.hoisted(() => vi.fn());

vi.mock('../services/shellExecutionService.js', () => ({
  ShellExecutionService: {
    execute: mockShellExecutionService,
    background: mockShellBackground,
  },
}));
"""
new = """const mockShellExecutionService = vi.hoisted(() => vi.fn());
const mockShellBackground = vi.hoisted(() => vi.fn());
const mockShellOnExit = vi.hoisted(() => vi.fn());

vi.mock('../services/shellExecutionService.js', () => ({
  ShellExecutionService: {
    execute: mockShellExecutionService,
    background: mockShellBackground,
    onExit: mockShellOnExit,
  },
}));
"""
assert old in s, 'mock block drifted'
s = s.replace(old, new, 1)
needle = """    it('should cancel the promotion timer when the command completes before the delay elapses', async () => {
"""
tests = """    it('should clean up the temp directory after a background process exits', async () => {
      vi.useFakeTimers();
      const invocation = shellTool.build({
        command: 'sleep 10',
        is_background: true,
      });
      const promise = invocation.execute({ abortSignal: mockAbortSignal });

      await vi.advanceTimersByTimeAsync(250);
      await promise;

      expect(
        mockShellOnExit,
        'background cleanup should be transferred to process exit',
      ).toHaveBeenCalledTimes(1);
      expect(mockShellOnExit).toHaveBeenCalledWith(12345, expect.any(Function));

      const tempDir = path.dirname(extractedTmpFile);
      expect(fs.existsSync(tempDir)).toBe(true);
      const exitCallback = mockShellOnExit.mock.calls[0][1] as (
        exitCode: number,
        signal?: number,
      ) => void;

      vi.useRealTimers();
      exitCallback(0);
      await vi.waitFor(() => expect(fs.existsSync(tempDir)).toBe(false));
    });

    it('should clean up the temp directory when a background request completes before promotion', async () => {
      vi.useFakeTimers();
      const invocation = shellTool.build({
        command: 'echo done',
        is_background: true,
      });
      const promise = invocation.execute({ abortSignal: mockAbortSignal });

      resolveShellExecution({ pid: 12345, output: 'done' });
      await promise;

      const tempDir = path.dirname(extractedTmpFile);
      expect(mockShellBackground).not.toHaveBeenCalled();
      expect(mockShellOnExit).not.toHaveBeenCalled();
      expect(fs.existsSync(tempDir)).toBe(false);
      vi.useRealTimers();
    });

"""
assert needle in s, 'background test insertion point drifted'
s = s.replace(needle, tests + needle, 1)
p.write_text(s)
PY
}

apply_source_patch() {
python3 - <<'PY'
from pathlib import Path
p = Path('packages/core/src/tools/shell.ts')
s = p.read_text()
old = """    let tempFilePath = '';
    let tempDir = '';

    const timeoutMs = this.context.config.getShellToolInactivityTimeout();
"""
new = """    let tempFilePath = '';
    let tempDir = '';
    let tempCleanupTransferred = false;

    const cleanupTempArtifacts = async () => {
      if (tempFilePath) {
        try {
          await fsPromises.unlink(tempFilePath);
        } catch {
          // Ignore errors during unlink
        }
      }
      if (tempDir) {
        try {
          await fsPromises.rm(tempDir, { recursive: true, force: true });
        } catch {
          // Ignore errors during rm
        }
      }
    };

    const timeoutMs = this.context.config.getShellToolInactivityTimeout();
"""
assert old in s, 'temp cleanup declaration point drifted'
s = s.replace(old, new, 1)
old = """              if (!completed) {
                ShellExecutionService.background(
                  pid,
                  sessionId,
                  strippedCommand,
                );
              }
"""
new = """              if (!completed) {
                ShellExecutionService.background(
                  pid,
                  sessionId,
                  strippedCommand,
                );
                tempCleanupTransferred = true;
                ShellExecutionService.onExit(pid, () => {
                  void cleanupTempArtifacts();
                });
              }
"""
assert old in s, 'background promotion block drifted'
s = s.replace(old, new, 1)
old = """      // Only clean up if NOT running in background.
      // Background processes need the temp directory and PID file to remain
      // available until they exit.
      if (!this.params.is_background) {
        if (tempFilePath) {
          try {
            await fsPromises.unlink(tempFilePath);
          } catch {
            // Ignore errors during unlink
          }
        }
        if (tempDir) {
          try {
            await fsPromises.rm(tempDir, { recursive: true, force: true });
          } catch {
            // Ignore errors during rm
          }
        }
      }
"""
new = """      // Promoted background commands keep their PID artifacts until the
      // underlying process exits. All other paths clean them up immediately.
      if (!tempCleanupTransferred) {
        await cleanupTempArtifacts();
      }
"""
assert old in s, 'final cleanup block drifted'
s = s.replace(old, new, 1)
p.write_text(s)
PY
}

apply_integration_patch() {
cat > integration-tests/shell-background-temp-cleanup.responses <<'EOF'
{"method":"generateContentStream","response":[{"candidates":[{"content":{"parts":[{"text":"I will start the short command in the background."},{"functionCall":{"name":"run_shell_command","args":{"command":"node -e \"setTimeout(() => {}, 2500)\"","is_background":true}}}],"role":"model"},"finishReason":"STOP","index":0}]}]}
{"method":"generateContentStream","response":[{"candidates":[{"content":{"parts":[{"text":"Background command started."}],"role":"model"},"finishReason":"STOP","index":0}]}]}
EOF
cat > integration-tests/shell-background-temp-cleanup.test.ts <<'EOF'
/**
 * @license
 * Copyright 2026 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { TestRig } from './test-helper.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function shellTempDirs(root: string): Promise<string[]> {
  const entries = await fs.readdir(root, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && entry.name.startsWith('gemini-shell-'))
    .map((entry) => entry.name);
}

async function waitForShellTempDir(
  root: string,
  shouldExist: boolean,
  timeoutMs: number,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const dirs = await shellTempDirs(root);
    if ((dirs.length > 0) === shouldExist) {
      return;
    }
    await delay(50);
  }

  const dirs = await shellTempDirs(root);
  if (shouldExist) {
    throw new Error('background shell temp directory was never created');
  }
  throw new Error(
    `background shell temp directory still exists after process exit: ${dirs.join(', ')}`,
  );
}

describe('background shell temp cleanup', () => {
  let rig: TestRig;

  beforeEach(() => {
    rig = new TestRig();
  });

  afterEach(async () => {
    await rig.cleanup();
  });

  it('removes actual shell temp artifacts after a background process exits', async () => {
    const tempRoot = await fs.mkdtemp(
      join(os.tmpdir(), 'gemini-shell-cleanup-root-'),
    );

    try {
      rig.setup('shell-background-temp-cleanup', {
        fakeResponsesPath: join(
          __dirname,
          'shell-background-temp-cleanup.responses',
        ),
        settings: {
          tools: {
            core: ['run_shell_command'],
          },
        },
      });

      const run = await rig.runInteractive({
        approvalMode: 'yolo',
        env: { TMPDIR: tempRoot },
      });

      await run.type('Start the short background command.');
      await run.type('\r');
      await run.expectText('Background command started.', 30000);

      await waitForShellTempDir(tempRoot, true, 5000);
      expect(await shellTempDirs(tempRoot)).not.toHaveLength(0);

      await waitForShellTempDir(tempRoot, false, 10000);
      expect(await shellTempDirs(tempRoot)).toHaveLength(0);
    } finally {
      await fs.rm(tempRoot, { recursive: true, force: true });
    }
  }, 30000);
});
EOF
}

mark_stage 'npm ci'
npm ci

mark_stage 'workspace build'
npm run build

mark_stage 'baseline unit regression patch'
apply_unit_test_patch

mark_stage 'prove current-main unit failure'
set +e
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts -t 'should clean up the temp directory after a background process exits' 2>&1 | tee /tmp/baseline-unit.log
baseline_unit_status=${PIPESTATUS[0]}
set -e
if [[ $baseline_unit_status -eq 0 ]]; then
  echo 'ERROR: baseline unit regression unexpectedly passed'
  exit 1
fi
grep -F 'background cleanup should be transferred to process exit' /tmp/baseline-unit.log >/dev/null
printf 'Verified intended unit baseline failure on %s\n' "$BASE_SHA"

git reset --hard "$BASE_SHA"
git clean -fd

mark_stage 'baseline integration regression patch'
apply_integration_patch

mark_stage 'prove current-main integration failure'
set +e
GEMINI_API_KEY=dummy RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests shell-background-temp-cleanup.test.ts 2>&1 | tee /tmp/baseline-integration.log
baseline_integration_status=${PIPESTATUS[0]}
set -e
if [[ $baseline_integration_status -eq 0 ]]; then
  echo 'ERROR: baseline integration regression unexpectedly passed'
  exit 1
fi
grep -F 'background shell temp directory still exists after process exit' /tmp/baseline-integration.log >/dev/null
printf 'Verified intended integration baseline failure on %s\n' "$BASE_SHA"

git reset --hard "$BASE_SHA"
git clean -fd

mark_stage 'apply minimal candidate and regressions'
apply_source_patch
apply_unit_test_patch
apply_integration_patch

mark_stage 'focused temp-directory unit regressions'
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts -t 'temp directory'

mark_stage 'full shell tool unit suite'
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts

mark_stage 'direct background temp cleanup integration'
GEMINI_API_KEY=dummy RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests shell-background-temp-cleanup.test.ts

mark_stage 'existing background shell integration coverage'
GEMINI_API_KEY=dummy RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests shell-background.test.ts

mark_stage 'full repository preflight'
npm run preflight

mark_stage 'final candidate diff review'
git add -N integration-tests/shell-background-temp-cleanup.responses integration-tests/shell-background-temp-cleanup.test.ts
git diff --check
expected=$'integration-tests/shell-background-temp-cleanup.responses\nintegration-tests/shell-background-temp-cleanup.test.ts\npackages/core/src/tools/shell.test.ts\npackages/core/src/tools/shell.ts'
actual="$(git diff --name-only | sort)"
printf 'Changed files:\n%s\n' "$actual"
test "$actual" = "$expected"
git diff -- packages/core/src/tools/shell.ts packages/core/src/tools/shell.test.ts integration-tests/shell-background-temp-cleanup.test.ts integration-tests/shell-background-temp-cleanup.responses

mark_stage 'complete'
