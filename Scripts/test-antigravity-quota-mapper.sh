#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Antigravity quota summary mapper: dual-group (UA >= 2.5.2), 3P-only (old UA) must NOT fake gemini 100%,
# ConnectRPC wrapper shape, bucket window/bucketId/displayName classification, ISO8601 resetTime.
OUT="/tmp/agentring-antigravity-quota-mapper-checks"
STUB="/tmp/agentring-antigravity-quota-test-stub.swift"

# 测试 stub：UsageLimitData 真身定义在 UsageData+Formatting.swift（拖入 L/UserSettings 等 UI 依赖），
# 独立编译 AntigravityUsageData.swift 只需存储形状。
cat > "$STUB" <<'EOF'
import Foundation

struct UsageLimitData {
    let percentage: Double
    let resetsAt: Date?
}
EOF

swiftc -swift-version 5 \
    AgentRing/Models/AntigravityUsageData.swift \
    "$STUB" \
    Tests/AntigravityQuotaMapperChecks.swift \
    -o "$OUT"
"$OUT"
rm -f "$OUT" "$STUB"
