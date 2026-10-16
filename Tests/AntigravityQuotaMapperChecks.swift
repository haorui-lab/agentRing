import Foundation

// Antigravity quota summary mapper checks against fixture JSON.
// Usage: Scripts/test-antigravity-quota-mapper.sh
// 场景覆盖：
// 1. 新版 UA（≥2.5.2）双组响应：Gemini/3P 各自正确匹配
// 2. 旧版 UA 单组（仅 3P）响应：geminiGroup/primary/secondary 必须 nil，禁止假 100%
// 3. 响应包装在 {"response": {...}} 的 ConnectRPC 形状
// 4. bucket window/bucketId/displayName 多形态归类
// 5. resetTime ISO8601（含/不含小数秒）解析

@main
struct AntigravityQuotaMapperChecks {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/antigravity-quota", isDirectory: true)

        checkDualGroups(root)
        checkSingleThreePGroupNoGeminiFallback(root)
        checkConnectRPCWrapper(root)
        checkBucketClassification()
        checkResetTimeParsing()

        print("All antigravity quota mapper checks passed.")
    }

    // MARK: - Fixtures

    /// 新版 UA 响应：Gemini Models + Claude and GPT models 两组
    static func checkDualGroups(_ root: URL) {
        let data = try! Data(contentsOf: root.appendingPathComponent("dual-groups.json"))
        let response = try! JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
        let usage = response.toUsageData()

        expect(usage.groups.count == 2, "dual groups parse count")
        expect(usage.geminiGroup?.displayName == "Gemini Models", "gemini group matched by name")
        expect(usage.thirdPartyGroup?.displayName == "Claude and GPT models", "3P group matched by name")

        let gemini = usage.geminiGroup
        expect(gemini?.weeklyLimit?.remainingFraction == 0.75, "gemini weekly remaining 0.75")
        expect(gemini?.weeklyLimit?.percentage == 25.0, "gemini weekly used 25%")
        expect(gemini?.fiveHourLimit?.remainingFraction == 0.25, "gemini 5h remaining 0.25")

        let third = usage.thirdPartyGroup
        expect(third?.weeklyLimit?.remainingFraction == 1.0, "3P weekly remaining 1.0")
        expect(third?.fiveHourLimit?.remainingFraction == 1.0, "3P 5h remaining 1.0")

        // primary/secondary 与 Gemini 组一致（不再回退到第一组）
        expect(usage.primary?.remainingFraction == 0.25, "primary is gemini 5h used-25% bucket")
        expect(usage.secondary?.remainingFraction == 0.75, "secondary is gemini weekly bucket")
        expect(usage.geminiPrimary != nil, "geminiPrimary present when gemini group exists")
        expect(usage.geminiSecondary != nil, "geminiSecondary present when gemini group exists")
    }

    /// 旧版 UA / 服务端异常时只返回 3P 组：Gemini 相关字段必须全 nil
    static func checkSingleThreePGroupNoGeminiFallback(_ root: URL) {
        let data = try! Data(contentsOf: root.appendingPathComponent("single-3p-group.json"))
        let response = try! JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
        let usage = response.toUsageData()

        expect(usage.groups.count == 1, "single 3P group count")
        expect(usage.geminiGroup == nil, "no gemini group matched from 3P-only response")
        expect(usage.geminiPrimary == nil, "geminiPrimary nil — must not fake 100% from 3P data")
        expect(usage.geminiSecondary == nil, "geminiSecondary nil — must not fake 100% from 3P data")
        expect(usage.primary == nil, "primary nil without gemini group")
        expect(usage.secondary == nil, "secondary nil without gemini group")

        // 3P 自身数据仍然正确可用
        expect(usage.thirdPartyGroup?.displayName == "Claude and GPT models", "3P group still matched")
        expect(usage.thirdPartyPrimary != nil, "3P primary present")
        expect(usage.thirdPartySecondary != nil, "3P secondary present")
    }

    /// ConnectRPC 包装形状 {"response": {"groups": [...]}}
    static func checkConnectRPCWrapper(_ root: URL) {
        let data = try! Data(contentsOf: root.appendingPathComponent("wrapper-response.json"))
        let response = try! JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
        let usage = response.toUsageData()

        expect(usage.groups.count == 2, "wrapper groups unwrapped")
        expect(usage.geminiGroup != nil, "wrapper gemini group matched")
        expect(usage.thirdPartyGroup != nil, "wrapper 3P group matched")
    }

    /// bucket 归类：window / bucketId / displayName 多形态
    static func checkBucketClassification() {
        func build(_ bucket: AntigravityQuotaResponse.BucketResponse) -> AntigravityUsageData {
            let group = AntigravityQuotaResponse.GroupResponse(
                displayName: "Gemini Models",
                description: nil,
                buckets: [bucket]
            )
            let response = AntigravityQuotaResponse(groups: [group], description: nil, response: nil)
            return response.toUsageData()
        }

        func usedOf(_ bucket: AntigravityQuotaResponse.BucketResponse) -> Double {
            build(bucket).geminiGroup.map { g in (g.fiveHourLimit ?? g.weeklyLimit)?.percentage ?? -1 } ?? -1
        }

        func classifiedAs5h(_ bucket: AntigravityQuotaResponse.BucketResponse) -> Bool {
            let g = build(bucket).geminiGroup
            return g?.fiveHourLimit != nil
        }

        expect(classifiedAs5h(AntigravityQuotaResponse.BucketResponse(
            bucketId: "gemini-5h", displayName: "Five Hour Limit Remaining",
            description: nil, window: "5h", remainingFraction: 0.9, resetTime: nil)),
            "window=5h classified as five hour")
        expect(!classifiedAs5h(AntigravityQuotaResponse.BucketResponse(
            bucketId: "gemini-weekly", displayName: "Weekly Limit Remaining",
            description: nil, window: "weekly", remainingFraction: 0.9, resetTime: nil)),
            "window=weekly classified as weekly")
        expect(!classifiedAs5h(AntigravityQuotaResponse.BucketResponse(
            bucketId: nil, displayName: "7 day limit",
            description: nil, window: nil, remainingFraction: 0.9, resetTime: nil)),
            "displayName '7 day' classified as weekly")
        expect(abs(usedOf(AntigravityQuotaResponse.BucketResponse(
            bucketId: "gemini-5h", displayName: "Five Hour Limit Remaining",
            description: nil, window: "5h", remainingFraction: 0.75, resetTime: nil)) - 25.0) < 0.001,
            "remaining 0.75 → used 25%")
    }

    /// resetTime 解析：含与不含小数秒的 ISO8601
    static func checkResetTimeParsing() {
        func resetDate(_ resetTime: String?) -> Date? {
            let group = AntigravityQuotaResponse.GroupResponse(
                displayName: "Gemini Models",
                description: nil,
                buckets: [AntigravityQuotaResponse.BucketResponse(
                    bucketId: "gemini-5h", displayName: "Five Hour Limit Remaining",
                    description: nil, window: "5h", remainingFraction: 1.0, resetTime: resetTime)]
            )
            let response = AntigravityQuotaResponse(groups: [group], description: nil, response: nil)
            return response.toUsageData().geminiGroup?.fiveHourLimit?.resetsAt
        }

        expect(resetDate("2026-10-16T07:09:59Z") != nil, "ISO8601 without fractional seconds parses")
        expect(resetDate("2026-10-16T07:09:59.123Z") != nil, "ISO8601 with fractional seconds parses")
        expect(resetDate(nil) == nil, "nil resetTime → nil date")
    }

    // MARK: - Helpers

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS: \(label)")
        } else {
            print("FAIL: \(label)")
            exit(1)
        }
    }
}
