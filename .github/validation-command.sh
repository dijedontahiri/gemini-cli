#!/usr/bin/env bash
set -euo pipefail

node --version
npm --version

echo 'Installing exact lockfile dependencies for issue #29424 shutdown diagnosis'
npm ci

echo 'Building workspaces before targeted tests'
npm run build

echo 'Verifying SDK Client.close delegates to its connected transport'
node --input-type=module <<'EOF'
import { Client } from '@modelcontextprotocol/sdk/client/index.js';

let closed = false;
const transport = {
  onclose: undefined,
  onerror: undefined,
  onmessage: undefined,
  async start() {},
  async send(message) {
    if (message.method === 'initialize' && message.id !== undefined) {
      const protocolVersion = message.params.protocolVersion;
      queueMicrotask(() => {
        transport.onmessage?.({
          jsonrpc: '2.0',
          id: message.id,
          result: {
            protocolVersion,
            capabilities: {},
            serverInfo: { name: 'shutdown-diagnostic', version: '1.0.0' },
          },
        });
      });
    }
  },
  async close() {
    closed = true;
    transport.onclose?.();
  },
};

const client = new Client(
  { name: 'shutdown-diagnostic-client', version: '1.0.0' },
  { capabilities: {} },
);
await client.connect(transport);
await client.close();
if (!closed) {
  throw new Error('SDK Client.close() did not close the attached transport');
}
console.log('PASS: SDK Client.close() invoked Transport.close()');
EOF

echo 'Verifying StdioClientTransport.close terminates its child process'
child_script="$(mktemp --suffix=.mjs)"
pid_file="$(mktemp)"
cleanup() {
  if [[ -s "$pid_file" ]]; then
    pid="$(cat "$pid_file" || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$child_script" "$pid_file"
}
trap cleanup EXIT

cat > "$child_script" <<'EOF'
import { writeFileSync } from 'node:fs';
writeFileSync(process.argv[2], String(process.pid));
process.stdin.resume();
setInterval(() => {}, 1000);
EOF

CHILD_SCRIPT="$child_script" PID_FILE="$pid_file" node --input-type=module <<'EOF'
import { readFile } from 'node:fs/promises';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const childScript = process.env.CHILD_SCRIPT;
const pidFile = process.env.PID_FILE;
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [childScript, pidFile],
});

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForPid() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const pid = Number((await readFile(pidFile, 'utf8')).trim());
      if (Number.isInteger(pid) && pid > 0) return pid;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('stdio transport child never wrote its pid');
}

async function waitForExit(pid) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (!isAlive(pid)) return true;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return !isAlive(pid);
}

await transport.start();
const pid = await waitForPid();
if (!isAlive(pid)) throw new Error('stdio transport child was not alive after start');
await transport.close();
if (!(await waitForExit(pid))) {
  throw new Error(`StdioClientTransport.close() left child ${pid} alive`);
}
console.log(`PASS: StdioClientTransport.close() terminated child ${pid}`);
EOF

echo 'Running existing MCP client regression suite on immutable upstream candidate'
npm test -w @google/gemini-cli-core -- src/tools/mcp-client.test.ts

echo 'Issue #29424 transport-lifecycle diagnosis complete'
