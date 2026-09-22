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

apply_test_patch() {
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

mark_stage 'npm ci'
npm ci

mark_stage 'workspace build'
npm run build

mark_stage 'baseline regression patch'
apply_test_patch

mark_stage 'prove current-main failure'
set +e
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts -t 'should clean up the temp directory after a background process exits' 2>&1 | tee /tmp/baseline.log
baseline_status=${PIPESTATUS[0]}
set -e
if [[ $baseline_status -eq 0 ]]; then
  echo 'ERROR: baseline regression test unexpectedly passed'
  exit 1
fi
grep -F 'background cleanup should be transferred to process exit' /tmp/baseline.log >/dev/null
printf 'Verified intended baseline failure on %s\n' "$BASE_SHA"

git reset --hard "$BASE_SHA"
git clean -fd

mark_stage 'apply minimal candidate and regression tests'
apply_source_patch
apply_test_patch

mark_stage 'focused temp-directory regression tests'
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts -t 'temp directory'

mark_stage 'full shell tool unit suite'
npm test -w @google/gemini-cli-core -- src/tools/shell.test.ts

mark_stage 'background shell integration coverage'
GEMINI_API_KEY=dummy RUN_FLAKY_INTEGRATION=1 GEMINI_SANDBOX=false npx vitest run --root ./integration-tests shell-background.test.ts

mark_stage 'full repository preflight'
npm run preflight

mark_stage 'final candidate diff review'
git diff --check
expected=$'packages/core/src/tools/shell.test.ts\npackages/core/src/tools/shell.ts'
actual="$(git diff --name-only | sort)"
printf 'Changed files:\n%s\n' "$actual"
test "$actual" = "$expected"
git diff -- packages/core/src/tools/shell.ts packages/core/src/tools/shell.test.ts

mark_stage 'complete'
