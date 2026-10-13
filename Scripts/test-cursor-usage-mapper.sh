#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Cursor usage mapper + presentation builder: legacy monthly, X-sub weekly, dashboard period+plan-info, ambiguous → legacy.
OUT="/tmp/agentring-cursor-usage-mapper-checks"
swiftc -swift-version 5 \
    AgentRing/Helpers/LoggerExtension.swift \
    AgentRing/Models/CursorUsageData.swift \
    AgentRing/Models/CursorPresentation.swift \
    Tests/CursorUsageMapperChecks.swift \
    -o "$OUT"
"$OUT" "$(pwd)/Tests/Fixtures/cursor-usage"
rm -f "$OUT"

# Localization keys required by presentation must exist in both catalogs.
for key in \
    "detail_row.cursor_included" \
    "detail_row.cursor_ondemand" \
    "detail_row.cursor_included_weekly" \
    "detail_row.cursor_additional_usage" \
    "detail_row.cursor_ondemand_spend"
do
    grep -q "\"$key\"" AgentRing/Resources/en.lproj/Localizable.strings \
        || { echo "FAIL: missing en key $key"; exit 1; }
    grep -q "\"$key\"" AgentRing/Resources/zh-Hans.lproj/Localizable.strings \
        || { echo "FAIL: missing zh-Hans key $key"; exit 1; }
    echo "PASS: localization key $key in en + zh-Hans"
done
