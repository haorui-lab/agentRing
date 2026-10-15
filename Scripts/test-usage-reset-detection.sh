#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="/tmp/agentring-usage-reset-detection-checks"
swiftc -swift-version 5 \
    AgentRing/Helpers/UsageResetDetector.swift \
    Tests/UsageResetDetectionChecks.swift \
    -o "$OUT"
"$OUT"
rm -f "$OUT"
