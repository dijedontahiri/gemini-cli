#!/usr/bin/env bash
set -euo pipefail

node --version
npm --version

echo 'Installing exact lockfile dependencies for issue #29424 reproduction'
npm ci

server_file="packages/core/src/tools/mcp-shutdown-repro-server.mjs"
test_file="packages/core/src/tools/mcp-client.shutdown-repro.test.ts"

cleanup() {
  rm -f "$server_file" "$test_file"
}
trap cleanup EXIT

cat > "$server_file" <<'EOF'
import { writeFileSync } from 'node:fs';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

const pidFile = process.argv[2];
writeFileSync(pidFile, String(process.pid));

const server = new Server(
  { name: 'gemini-cli-shutdown-repro', version: '1.0.0' },
  { capabilities: {} },
);
await server.connect(new StdioServerTransport());
EOF

cat > "$test_file" <<'EOF'
/**
 * @license
 * Copyright 2026 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WorkspaceContext } from '../utils/workspaceContext.js';
import type { EnvironmentSanitizationConfig } from '../services/environmentSanitization.js';
import {
  McpClient,
  MCPServerStatus,
  type McpContext,
} from './mcp-client.js';

const EMPTY_CONFIG: EnvironmentSanitizationConfig = {
  enableEnvironmentVariableRedaction: true,
  allowedEnvironmentVariables: [],
  blockedEnvironmentVariables: [],
};

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForPidFile(pidFile: string): Promise<number> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const value = await readFile(pidFile, 'utf8');
      return Number(value.trim());
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  throw new Error('MCP repro server never wrote its pid file');
}

async function waitForProcessExit(pid: number): Promise<boolean> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return !isProcessAlive(pid);
}

describe('issue #29424 shutdown reproduction', () => {
  let tempDir: string | undefined;
  let workspaceContext: WorkspaceContext | undefined;

  afterEach(async () => {
    vi.restoreAllMocks();
    if (tempDir) await rm(tempDir, { recursive: true, force: true });
    tempDir = undefined;
    workspaceContext = undefined;
  });

  it('McpClient.disconnect terminates a real stdio MCP child process', async () => {
    tempDir = await mkdtemp(path.join(tmpdir(), 'gemini-mcp-shutdown-repro-'));
    workspaceContext = new WorkspaceContext(tempDir);
    const pidFile = path.join(tempDir, 'server.pid');
    const serverFile = path.resolve(
      'packages/core/src/tools/mcp-shutdown-repro-server.mjs',
    );

    const context: McpContext = {
      sanitizationConfig: EMPTY_CONFIG,
      emitMcpDiagnostic: vi.fn(),
      isTrustedFolder: () => true,
    };

    const client = new McpClient(
      'shutdown-repro',
      {
        command: process.execPath,
        args: [serverFile, pidFile],
      },
      workspaceContext,
      context,
      false,
      '0.0.0-repro',
    );

    await client.connect();
    expect(client.getStatus()).toBe(MCPServerStatus.CONNECTED);

    const childPid = await waitForPidFile(pidFile);
    expect(isProcessAlive(childPid)).toBe(true);

    await client.disconnect();
    expect(client.getStatus()).toBe(MCPServerStatus.DISCONNECTED);
    expect(await waitForProcessExit(childPid)).toBe(true);
  }, 15000);
});
EOF

echo 'Running real-stdio MCP shutdown reproduction on immutable upstream candidate'
npm test -w @google/gemini-cli-core -- src/tools/mcp-client.shutdown-repro.test.ts

echo 'Running existing MCP client regression suite'
npm test -w @google/gemini-cli-core -- src/tools/mcp-client.test.ts

echo 'Reproduction command complete'
