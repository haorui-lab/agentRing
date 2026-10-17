//
//  SensitiveDataRedactor.swift
//  Agent Ring
//

import Foundation

/// 敏感数据脱敏工具
/// 提供统一的敏感信息脱敏方法，用于日志记录和诊断报告
/// 支持 Codex session-token、refresh-token、access-token 和文本中的敏感信息脱敏
class SensitiveDataRedactor {
    // MARK: - Public Methods

    /// 脱敏 Codex Session Token（JWE 长串）
    /// - Parameter token: __Secure-next-auth.session-token 的值
    /// - Returns: 脱敏后的字符串，保留前8位和后4位
    static func redactCodexSessionToken(_ token: String) -> String {
        guard token.count > 12 else {
            return String(repeating: "*", count: token.count)
        }
        return "\(token.prefix(8))...\(token.suffix(4)) (\(token.count) chars)"
    }

    /// 脱敏 JWT Access Token（三段式 header.payload.signature）
    /// - Parameter token: Bearer accessToken 字符串
    /// - Returns: 脱敏后的字符串，每段只保留前6字符
    static func redactAccessToken(_ token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            guard token.count > 12 else { return "***" }
            return "\(token.prefix(8))...\(token.suffix(4)) (\(token.count) chars)"
        }
        let h = String(parts[0].prefix(6))
        let p = String(parts[1].prefix(6))
        let s = String(parts[2].prefix(6))
        return "\(h)...\(p)...\(s)... (\(token.count) chars)"
    }

    private static let textReplacements: [(regex: NSRegularExpression, template: String)] = {
        // 同时覆盖 JSON、Cookie、URL query 和 key=value；键名必须完整匹配。
        let tokenKeys = #"(?:__Secure-next-auth\.session-token(?:\.\d+)?|session-token(?:\.\d+)?|refresh_token|refreshToken|access_token|accessToken|id_token|idToken)"#
        let replacements: [(pattern: String, template: String)] = [
            (#"((?<![\w.-])"# + tokenKeys + #"["']?\s*[=:]\s*["']?)[^;\s"'&,}\]]+"#, "$1***REDACTED***"),
            (#"((?<![\w.-])Authorization["']?\s*:\s*["']?Bearer\s+)[^;\s"',}\]]+"#, "$1***REDACTED***")
        ]

        return replacements.map {
            // 固定的正则仅编译一次，避免每条诊断日志重复编译。
            (try! NSRegularExpression(pattern: $0.pattern, options: .caseInsensitive), $0.template)
        }
    }()

    /// 脱敏日志和诊断文本中的常见凭证字段，保留外围格式。
    static func redactText(_ text: String) -> String {
        var sanitized = text

        for replacement in textReplacements {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = replacement.regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }

        return sanitized
    }
}
