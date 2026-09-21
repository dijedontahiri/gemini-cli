#!/usr/bin/env bash
set -euo pipefail

node --version
npm --version

echo 'Installing exact lockfile dependencies for interactive SessionEnd regression validation'
npm ci

echo 'Building workspaces required by CLI tests'
npm run build

echo 'Checking current interactive SessionEnd cleanup registrations on immutable upstream candidate'
git grep -n "fireSessionEndEvent(SessionEndReason.Exit)" -- \
  packages/cli/src/gemini.tsx \
  packages/cli/src/ui/AppContainer.tsx

node --input-type=module <<'EOF'
import { readFileSync } from 'node:fs';

const gemini = readFileSync('packages/cli/src/gemini.tsx', 'utf8');
const app = readFileSync('packages/cli/src/ui/AppContainer.tsx', 'utf8');

const sharedRegistration = /registerCleanup\(async \(\) => \{\s*await config\?\.getHookSystem\(\)\?\.fireSessionEndEvent\(SessionEndReason\.Exit\);\s*\}\);/s.test(gemini);
const interactiveRegistration = /const cleanupFn = async \(\) => \{[\s\S]*?fireSessionEndEvent\(SessionEndReason\.Exit\);[\s\S]*?\};\s*registerCleanup\(cleanupFn\);/s.test(app);

if (!sharedRegistration || !interactiveRegistration) {
  throw new Error(
    `Expected duplicate interactive SessionEnd cleanup registrations were not both present: shared=${sharedRegistration}, app=${interactiveRegistration}`,
  );
}

console.log('REPRODUCED: interactive sessions install both shared gemini.tsx and AppContainer SessionEnd cleanup registrations');
EOF

echo 'Running existing cleanup regression suite (currently covers non-interactive duplicate prevention)'
npm test -w @google/gemini-cli -- src/gemini_cleanup.test.tsx

echo 'Running AppContainer tests around interactive lifecycle cleanup'
npm test -w @google/gemini-cli -- src/ui/AppContainer.test.tsx

echo 'Interactive SessionEnd regression validation complete'
