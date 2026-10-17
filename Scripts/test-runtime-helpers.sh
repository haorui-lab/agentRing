#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 \
    AgentRing/Helpers/TimerManager.swift \
    AgentRing/Helpers/SensitiveDataRedactor.swift \
    Tests/RuntimeHelperChecks.swift -o "$WORK/runtime-helper-checks"
"$WORK/runtime-helper-checks"
