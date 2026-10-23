#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -r "$TEST_DIR"' EXIT
swiftc "$REPO_ROOT/AgentRing/Services/BLEConnectionPolicy.swift" "$REPO_ROOT/Tests/BLEConnectionPolicyChecks.swift" -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
