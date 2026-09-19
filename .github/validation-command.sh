#!/usr/bin/env bash
set -euo pipefail
node --version
npm --version
git status --short
node -e "const p=require('./package.json'); console.log(p.name ?? 'gemini-cli')"
