#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# 判断 Cursor 登录该从哪个 URL 开始，以及哪些 WorkOS 路由不能当成登录页展示。
swiftc -swift-version 5 \
    AgentRing/Views/WebLogin/CursorLoginNavigation.swift \
    Tests/CursorLoginNavigationChecks.swift -o /tmp/agentring-cursor-login-navigation-checks
/tmp/agentring-cursor-login-navigation-checks
rm /tmp/agentring-cursor-login-navigation-checks
