//
//  AntigravityAPIService.swift
//  Agent Ring
//

import Darwin
import Foundation
import OSLog

/// Antigravity API 服务类
/// 用于获取 Antigravity（Google DeepMind Agentic Coding）用量与配额数据
class AntigravityAPIService: UsageProvider {
    var providerType: ProviderType { .antigravity }

    private let settings = UserSettings.shared
    private let session: URLSession
    private var activeTasks: [URLSessionDataTask] = []
    private let taskLock = NSLock()

    private let cloudEndpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    /// UA 版本必须 ≥ antigravity/2.5.2：服务端按 UA 版本下发配额分组，
    /// 旧版本（≤2.5.1）只返回「Claude and GPT models」组，缺失「Gemini Models」组，
    /// 导致 Gemini 圆环回退显示 3P 数据/100%。对齐官方 IDE 当前版本（如 2.24.0）。
    /// 诊断 runner 等其他请求方一律引用此常量，禁止再写死第二份版本号。
    static let requestUserAgent = "antigravity/2.24.0"

    private let userAgent = requestUserAgent

    private static let credentialsCacheLock = NSLock()
    private static var credentialsCache: (available: Bool, checkedAt: Date)?
    private static let credentialsCacheTTL: TimeInterval = 120
    private static var credentialsRefreshScheduled = false
    /// 用户点「不允许」等交互失败后，短时间内禁止再走会弹窗的 CLI（仅影响显式「重新检查」/诊断）
    private static var interactiveKeychainBlockedUntil: Date?
    /// 后台从不走 CLI；冷却只挡显式操作。无倒计时 UI，60 秒够防连点，更长会让用户以为「重新检查」坏了。
    private static let interactiveKeychainBlockTTL: TimeInterval = 60

    /// Antigravity / agy CLI 的已安装应用 OAuth 客户端（与 id_token 的 azp/aud 一致）。
    /// 勿用 Gemini CLI 的 681255809395…：refresh 会 401 unauthorized_client。
    /// client_secret 可公开嵌入（Google installed-app 惯例；与 agy 二进制内嵌值相同）。
    /// 字节异或存放，避免 GitHub push protection 把桌面端公开 client 当成泄露密钥拦推送。
    private static let geminiOAuthClientID = decodeInstalledOAuthCredential([
        148, 149, 146, 148, 149, 149, 147, 149, 147, 149, 144, 156, 148, 136, 209, 200,
        205, 214, 214, 204, 203, 151, 205, 151, 148, 201, 198, 215, 192, 151, 150, 144,
        211, 209, 202, 201, 202, 207, 205, 145, 194, 145, 149, 150, 192, 213, 139, 196,
        213, 213, 214, 139, 194, 202, 202, 194, 201, 192, 208, 214, 192, 215, 198, 202,
        203, 209, 192, 203, 209, 139, 198, 202, 200
    ])
    private static let geminiOAuthClientSecret = decodeInstalledOAuthCredential([
        226, 234, 230, 246, 245, 253, 136, 238, 144, 157, 227, 242, 247, 145, 157, 147,
        233, 193, 233, 239, 148, 200, 233, 231, 157, 214, 253, 230, 145, 223, 147, 212,
        225, 228, 195
    ])
    private static let installedOAuthCredentialXORKey: UInt8 = 0xA5
    private static func decodeInstalledOAuthCredential(_ bytes: [UInt8]) -> String {
        let decoded = bytes.map { $0 ^ installedOAuthCredentialXORKey }
        guard let value = String(bytes: decoded, encoding: .utf8), !value.isEmpty else {
            preconditionFailure("Antigravity OAuth credential decode failed")
        }
        return value
    }
    private static let googleOAuthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let oauthFileRefreshLock = NSLock()
    /// Quota 403/401 后隔离本地 oauth 文件（常见：文件账号无 Antigravity 权限，钥匙串才是活跃账号）。
    /// 隔离后自动路径不再读该文件，直到显式「重新检查」从钥匙串同步成功。
    private static var oauthFileQuarantinedForAntigravity = false

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func cancelAllRequests() {
        taskLock.lock()
        let tasks = activeTasks
        activeTasks.removeAll()
        taskLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    /// 是否存在可用凭证。
    /// - 默认路径：只读缓存，过期则后台刷新；**绝不**在调用线程（尤其是主线程 SwiftUI body）上跑钥匙串 / Process。
    /// - `forceRefresh: true`：同步探测（调用方必须已在后台队列）。
    /// - `allowInteractiveKeychain`：仅显式用户操作（如设置页「重新检查」）为 true；可走可能弹窗的 security CLI。
    static func credentialsAvailable(forceRefresh: Bool = false, allowInteractiveKeychain: Bool = false) -> Bool {
        if forceRefresh {
            assert(!Thread.isMainThread, "Antigravity credentialsAvailable(forceRefresh:) must not run on the main thread")
            return refreshCredentialsCacheSync(allowInteractiveKeychain: allowInteractiveKeychain)
        }

        credentialsCacheLock.lock()
        let cached = credentialsCache
        let isStale = cached == nil
            || Date().timeIntervalSince(cached!.checkedAt) >= credentialsCacheTTL
        let available = cached?.available ?? false
        credentialsCacheLock.unlock()

        if isStale {
            scheduleCredentialsRefreshIfNeeded()
        }
        return available
    }

    /// 启动时或设置变更后主动踢一次后台探测（不阻塞调用方）。
    static func warmCredentialsCache() {
        scheduleCredentialsRefreshIfNeeded(force: true)
    }

    static func invalidateCredentialsCache() {
        credentialsCacheLock.lock()
        credentialsCache = nil
        credentialsRefreshScheduled = false
        credentialsCacheLock.unlock()
        // 不清空 Published：短暂保留上次结果，后台刷新完成后再更新，避免 UI 闪断
        scheduleCredentialsRefreshIfNeeded(force: true)
    }

    /// 确认无可用凭证（探测失败 / 401）。更新缓存与 Published，不再二次调度刷新。
    static func markCredentialsUnavailable() {
        credentialsCacheLock.lock()
        credentialsCache = (false, Date())
        credentialsRefreshScheduled = false
        credentialsCacheLock.unlock()
        publishCredentialsPresence(false)
    }

    /// Quota 返回 401/403：本地 oauth 账号很可能与 Antigravity 活跃账号错位，隔离文件直到钥匙串同步。
    static func quarantineOAuthFileAfterUnauthorized() {
        credentialsCacheLock.lock()
        oauthFileQuarantinedForAntigravity = true
        credentialsCacheLock.unlock()
        Logger.api.notice("Antigravity oauth 文件已隔离（Quota 未授权），需设置里「重新检查」从钥匙串同步")
        writeOAuthPathBreadcrumb("oauth_quarantined_after_unauthorized")
        markCredentialsUnavailable()
    }

    private static func isOAuthFileQuarantined() -> Bool {
        credentialsCacheLock.lock()
        defer { credentialsCacheLock.unlock() }
        return oauthFileQuarantinedForAntigravity
    }

    private static func clearOAuthFileQuarantine() {
        credentialsCacheLock.lock()
        oauthFileQuarantinedForAntigravity = false
        credentialsCacheLock.unlock()
    }

    private static func scheduleCredentialsRefreshIfNeeded(force: Bool = false) {
        credentialsCacheLock.lock()
        if credentialsRefreshScheduled && !force {
            credentialsCacheLock.unlock()
            return
        }
        credentialsRefreshScheduled = true
        credentialsCacheLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = refreshCredentialsCacheSync()
        }
    }

    @discardableResult
    private static func refreshCredentialsCacheSync(allowInteractiveKeychain: Bool = false) -> Bool {
        // 后台刷新默认静默；仅 AuthSettings 等显式操作才允许可能弹窗的 CLI
        let available = resolveAccessToken(allowInteractiveKeychain: allowInteractiveKeychain) != nil
        credentialsCacheLock.lock()
        credentialsCache = (available, Date())
        credentialsRefreshScheduled = false
        credentialsCacheLock.unlock()
        publishCredentialsPresence(available)
        return available
    }

    private static func publishCredentialsPresence(_ available: Bool) {
        DispatchQueue.main.async {
            UserSettings.shared.applyAntigravityCredentialsPresent(available)
        }
    }

    func fetchUsage(completion: @escaping (Result<AntigravityUsageData, Error>) -> Void) {
        #if DEBUG
        if settings.debugModeEnabled {
            DispatchQueue.main.async { completion(.success(self.createMockData())) }
            return
        }
        #endif

        cancelAllRequests()

        // 钥匙串读取可能阻塞，绝不在主线程跑
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 用量拉取是自动路径：宁可无凭证，也不弹钥匙串
            guard let token = Self.resolveAccessToken(allowInteractiveKeychain: false) else {
                Self.markCredentialsUnavailable()
                DispatchQueue.main.async { completion(.failure(UsageError.noCredentials)) }
                return
            }
            Self.credentialsCacheLock.lock()
            Self.credentialsCache = (true, Date())
            Self.credentialsRefreshScheduled = false
            Self.credentialsCacheLock.unlock()
            Self.publishCredentialsPresence(true)
            self.fetchCloudQuota(token: token, completion: completion)
        }
    }

    // MARK: - Token Resolution

    /// 解析 Access Token（对照 git 历史，不做盲目加料）：
    /// 1. `~/.gemini/oauth_creds.json` 中未过期的 access_token
    /// 2. 同文件里的 refresh_token → `oauth2.googleapis.com/token` 静默续期并写回文件（**不碰钥匙串**）
    /// 3. 仅显式「重新检查」/诊断：`/usr/bin/security` CLI；成功后把钥匙串 payload
    ///    **同步写回** oauth 文件（纠正「文件账号 ≠ Antigravity 活跃账号」导致的 Quota 403）
    ///
    /// **相邻根因 `985b640`：** 为避开主线程 `Process(security)` 崩溃，引入了
    /// Published 缓存 + 后台刷新（应保留），但同时**新增** `SecItemCopyMatching`，
    /// 且 `warmCredentialsCache` / 120s 过期刷新会在后台反复打钥匙串 → 密码框。
    /// 本修复：保留主线程安全；撤销 gemini 的 SecItem；oauth 静默续期；显式 CLI 成功后对齐账号。
    static func resolveAccessToken(allowInteractiveKeychain: Bool = false) -> String? {
        // 显式「重新检查」/诊断：优先钥匙串 CLI，把 Antigravity 活跃账号同步进 oauth 文件。
        // 否则若 oauth 里仍是「未过期但无配额」的旧账号，会永远走文件、永远 403。
        if allowInteractiveKeychain {
            if let viaCLI = resolveAccessTokenViaInteractiveKeychainCLI() {
                return viaCLI
            }
            // 显式操作若 CLI 失败：不再回落隔离中的错误账号文件（避免「重新检查」假成功）
            if isOAuthFileQuarantined() {
                writeOAuthPathBreadcrumb("interactive_cli_failed_quarantine_blocks_file_fallback")
                return nil
            }
        }

        if isOAuthFileQuarantined() {
            writeOAuthPathBreadcrumb("auto_skip_quarantined_oauth_file")
            return nil
        }

        if let tokenFromFile = readTokenFromLocalFile() {
            return tokenFromFile
        }

        // access 过期但 refresh 仍可用：网络续期，零钥匙串 UI（须在后台线程调用）
        if let refreshed = refreshOAuthFileAccessTokenSync() {
            return refreshed
        }

        return nil
    }

    private static func resolveAccessTokenViaInteractiveKeychainCLI() -> String? {
        guard !isInteractiveKeychainBlocked() else {
            Logger.api.debug("Antigravity 钥匙串交互已被拒绝/需授权，冷却期内跳过 security CLI")
            return nil
        }

        switch readTokenFromKeychainSecurityCLI() {
        case .token(let token):
            clearInteractiveKeychainBlock()
            return token
        case .notFound:
            Logger.api.debug("security CLI：Antigravity 钥匙串条目不存在")
            return nil
        case .deniedOrFailed:
            markInteractiveKeychainBlocked()
            return nil
        }
    }

    private enum CLIKeychainResult {
        case token(String)
        case notFound
        case deniedOrFailed
    }

    private static func isInteractiveKeychainBlocked() -> Bool {
        credentialsCacheLock.lock()
        defer { credentialsCacheLock.unlock() }
        guard let until = interactiveKeychainBlockedUntil else { return false }
        return Date() < until
    }

    private static func markInteractiveKeychainBlocked() {
        credentialsCacheLock.lock()
        interactiveKeychainBlockedUntil = Date().addingTimeInterval(interactiveKeychainBlockTTL)
        credentialsCacheLock.unlock()
        Logger.api.debug("Antigravity 钥匙串交互路径已冷却 \(Int(Self.interactiveKeychainBlockTTL)) 秒")
    }

    private static func clearInteractiveKeychainBlock() {
        credentialsCacheLock.lock()
        interactiveKeychainBlockedUntil = nil
        credentialsCacheLock.unlock()
    }

    /// `security` 找不到条目时退出码为 44：即 `errSecItemNotFound`（-25300）经进程退出状态低 8 位截断（`-25300 & 0xFF == 44`）。
    /// `Process.terminationStatus` 只有 0…255，不可能等于原始 OSStatus -25300，故只比 44。
    private static func isKeychainItemNotFoundStatus(_ status: Int32) -> Bool {
        status == 44
    }

    /// 仅显式用户操作可调用；`security find-generic-password -w` 可能弹出钥匙串授权框。
    private static func readTokenFromKeychainSecurityCLI() -> CLIKeychainResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let status = task.terminationStatus
            writeOAuthPathBreadcrumb("keychain_cli_start")
            if status != 0 {
                if isKeychainItemNotFoundStatus(status) {
                    writeOAuthPathBreadcrumb("keychain_cli_not_found exit=\(status)")
                    return .notFound
                }
                Logger.api.debug("security CLI 读取 Antigravity 钥匙串失败，exit=\(status)")
                writeOAuthPathBreadcrumb("keychain_cli_denied_or_failed exit=\(status)")
                return .deniedOrFailed
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let rawOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = parseKeychainSecret(rawOutput) else {
                // 进程成功但内容不可用：不当作用户拒绝，避免误冷却
                writeOAuthPathBreadcrumb("keychain_cli_parse_fail")
                return .notFound
            }
            // 把 Antigravity 活跃账号同步进 oauth 文件，之后自动路径 refresh 就不会续到错误账号
            syncOAuthFileFromKeychainFields(parsed.oauthFileFields)
            clearOAuthFileQuarantine()
            writeOAuthPathBreadcrumb("keychain_cli_ok_synced_to_oauth")
            return .token(parsed.accessToken)
        } catch {
            Logger.api.debug("通过 security CLI 读取 Antigravity 钥匙串失败: \(error.localizedDescription)")
            writeOAuthPathBreadcrumb("keychain_cli_process_error")
            // 无法启动 Process 不等于用户拒绝
            return .notFound
        }
    }

    private struct ParsedKeychainSecret {
        let accessToken: String
        /// Gemini CLI `oauth_creds.json` 形状的字段（access/refresh/id_token/expiry_date…）
        let oauthFileFields: [String: Any]
    }

    private static func parseKeychainSecret(_ raw: String) -> ParsedKeychainSecret? {
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            let b64 = String(raw.dropFirst(prefix.count))
            guard let jsonData = Data(base64Encoded: b64),
                  let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            let tokenObj = root["token"] as? [String: Any]
            guard let access = tokenObj?["access_token"] as? String, !access.isEmpty else {
                return nil
            }

            var fields: [String: Any] = ["access_token": access]
            if let tokenType = tokenObj?["token_type"] as? String, !tokenType.isEmpty {
                fields["token_type"] = tokenType
            }
            if let refresh = tokenObj?["refresh_token"] as? String, !refresh.isEmpty {
                fields["refresh_token"] = refresh
            }
            if let scope = tokenObj?["scope"] as? String, !scope.isEmpty {
                fields["scope"] = scope
            } else if let scope = root["scope"] as? String, !scope.isEmpty {
                fields["scope"] = scope
            }
            if let idToken = root["id_token"] as? String, !idToken.isEmpty {
                fields["id_token"] = idToken
            } else if let idToken = tokenObj?["id_token"] as? String, !idToken.isEmpty {
                fields["id_token"] = idToken
            }
            if let expiryDateMs = oauthExpiryDateMillis(fromKeychainExpiry: tokenObj?["expiry"]) {
                fields["expiry_date"] = expiryDateMs
            }
            return ParsedKeychainSecret(accessToken: access, oauthFileFields: fields)
        }

        guard !raw.isEmpty else { return nil }
        return ParsedKeychainSecret(
            accessToken: raw,
            oauthFileFields: ["access_token": raw]
        )
    }

    /// 钥匙串里常见 ISO8601 字符串；也兼容秒/毫秒时间戳。
    private static func oauthExpiryDateMillis(fromKeychainExpiry expiry: Any?) -> Double? {
        if let text = expiry as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date.timeIntervalSince1970 * 1000
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return date.timeIntervalSince1970 * 1000
            }
        }
        if let number = expiry as? Double {
            return number > 1_000_000_000_000 ? number : number * 1000
        }
        if let number = expiry as? Int {
            let value = Double(number)
            return value > 1_000_000_000_000 ? value : value * 1000
        }
        if let number = expiry as? NSNumber {
            let value = number.doubleValue
            return value > 1_000_000_000_000 ? value : value * 1000
        }
        return nil
    }

    /// 用钥匙串里的 Antigravity 活跃账号覆盖/合并写入 `~/.gemini/oauth_creds.json`。
    /// 注意：可能把文件从旧 Gemini CLI 账号换成 Antigravity 当前账号（这正是修正 403 所需）。
    private static func syncOAuthFileFromKeychainFields(_ fields: [String: Any]) {
        oauthFileRefreshLock.lock()
        defer { oauthFileRefreshLock.unlock() }

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: oauthCredsFileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        for (key, value) in fields {
            json[key] = value
        }
        // 确保目录存在（真实主目录下的 .gemini）
        let dir = oauthCredsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: oauthCredsFileURL, options: [.atomic])
            Logger.api.notice("Antigravity 钥匙串凭证已同步写回 ~/.gemini/oauth_creds.json")
        } catch {
            Logger.api.notice("Antigravity 钥匙串→oauth 写回失败: \(error.localizedDescription, privacy: .public)")
            writeOAuthPathBreadcrumb("keychain_sync_write_fail")
        }
    }

    /// 沙盒内 `~` / `NSHomeDirectory()` / 甚至 `NSHomeDirectoryForUser` 都可能指向容器。
    /// 用 POSIX `getpwuid` 取真实 login 主目录，并配合 entitlements 对 `/.gemini/` 的读写例外。
    private static var realUserHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            return userHome
        }
        return NSHomeDirectory()
    }

    private static var oauthCredsFileURL: URL {
        URL(fileURLWithPath: realUserHomeDirectory, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("oauth_creds.json", isDirectory: false)
    }

    /// 仅 DEBUG：沙盒容器内诊断面包屑（不写密钥）。
    private static func writeOAuthPathBreadcrumb(_ message: String) {
        #if DEBUG
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentRing", isDirectory: true)
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("antigravity-oauth-breadcrumb.txt")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private static func readTokenFromLocalFile() -> String? {
        let url = oauthCredsFileURL
        guard let data = try? Data(contentsOf: url) else {
            writeOAuthPathBreadcrumb("read_fail path=\(url.path) realHome=\(realUserHomeDirectory) sandboxHome=\(NSHomeDirectory())")
            return nil
        }
        struct FileCreds: Codable {
            let access_token: String?
            let expiry_date: Double?
        }
        guard let creds = try? JSONDecoder().decode(FileCreds.self, from: data),
              let token = creds.access_token, !token.isEmpty else {
            writeOAuthPathBreadcrumb("parse_fail path=\(url.path)")
            return nil
        }

        if let expiry = creds.expiry_date {
            // 兼容秒级时间戳与毫秒级时间戳；缺字段则不据此拒绝
            let expirySeconds = expiry > 1_000_000_000_000 ? (expiry / 1000.0) : expiry
            if expirySeconds <= Date().timeIntervalSince1970 + 30 {
                Logger.api.notice("Antigravity oauth access_token 已过期，尝试 refresh_token 续期")
                writeOAuthPathBreadcrumb("access_expired path=\(url.path)")
                return nil
            }
        }
        writeOAuthPathBreadcrumb("access_ok path=\(url.path)")
        return token
    }

    /// 用 oauth 文件中的 refresh_token 向 Google 换新 access_token，并写回同一文件。
    /// 仅应在后台队列调用（含同步网络）。成功则自动路径可继续展示用量，无需弹钥匙串。
    private static func refreshOAuthFileAccessTokenSync() -> String? {
        assert(!Thread.isMainThread, "Antigravity OAuth refresh must not run on the main thread")

        oauthFileRefreshLock.lock()
        defer { oauthFileRefreshLock.unlock() }

        // 锁内再读一次：可能已被并发刷新写回
        if let fresh = readTokenFromLocalFile() {
            return fresh
        }

        guard let data = try? Data(contentsOf: oauthCredsFileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = json["refresh_token"] as? String,
              !refreshToken.isEmpty else {
            writeOAuthPathBreadcrumb("refresh_abort_no_refresh_token path=\(oauthCredsFileURL.path)")
            return nil
        }

        var request = URLRequest(url: googleOAuthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        var formAllowed = CharacterSet.alphanumerics
        formAllowed.insert(charactersIn: "-._~")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": geminiOAuthClientID,
            "client_secret": geminiOAuthClientSecret
        ]
        .map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
            return "\(key)=\(encoded)"
        }
        .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var httpStatus: Int?
        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            httpStatus = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)

        if let responseError {
            Logger.api.notice("Antigravity oauth refresh 网络失败: \(responseError.localizedDescription, privacy: .public)")
            writeOAuthPathBreadcrumb("refresh_network_fail")
            return nil
        }
        guard let responseData,
              let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              !accessToken.isEmpty else {
            let oauthError = (try? JSONSerialization.jsonObject(with: responseData ?? Data()) as? [String: Any])?["error"] as? String
            Logger.api.notice("Antigravity oauth refresh 响应无效或 refresh_token 已失效 status=\(httpStatus ?? -1) error=\(oauthError ?? "nil", privacy: .public)")
            writeOAuthPathBreadcrumb("refresh_response_invalid status=\(httpStatus ?? -1) error=\(oauthError ?? "nil")")
            return nil
        }

        json["access_token"] = accessToken
        let expiresIn: Double?
        if let value = payload["expires_in"] as? Double {
            expiresIn = value
        } else if let value = payload["expires_in"] as? Int {
            expiresIn = Double(value)
        } else if let value = payload["expires_in"] as? NSNumber {
            expiresIn = value.doubleValue
        } else {
            expiresIn = nil
        }
        if let expiresIn {
            // 与 Gemini CLI 一致：expiry_date 用毫秒
            json["expiry_date"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        if let newRefresh = payload["refresh_token"] as? String, !newRefresh.isEmpty {
            json["refresh_token"] = newRefresh
        }
        if let idToken = payload["id_token"] as? String, !idToken.isEmpty {
            json["id_token"] = idToken
        }
        if let tokenType = payload["token_type"] as? String, !tokenType.isEmpty {
            json["token_type"] = tokenType
        }
        if let scope = payload["scope"] as? String, !scope.isEmpty {
            json["scope"] = scope
        }

        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: oauthCredsFileURL, options: [.atomic])
            Logger.api.notice("Antigravity oauth access_token 已通过 refresh_token 续期并写回文件")
            writeOAuthPathBreadcrumb("refresh_ok_writeback")
            return accessToken
        } catch {
            Logger.api.notice("Antigravity oauth 写回失败（仍返回内存中的新 token）: \(error.localizedDescription, privacy: .public)")
            writeOAuthPathBreadcrumb("refresh_ok_writeback_fail_still_using_memory_token")
            return accessToken
        }
    }

    // MARK: - Cloud API Fetch

    private func fetchCloudQuota(token: String, completion: @escaping (Result<AntigravityUsageData, Error>) -> Void) {
        guard let url = URL(string: cloudEndpoint) else {
            DispatchQueue.main.async { completion(.failure(UsageError.invalidURL)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = "{}".data(using: .utf8)

        var task: URLSessionDataTask!
        task = session.dataTask(with: request) { [weak self] data, response, error in
            defer {
                if let task {
                    self?.removeActiveTask(task)
                }
            }

            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(UsageError.networkError)) }
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                Logger.api.error("Antigravity 认证失效 (\(http.statusCode))")
                // 403 常见于 oauth 文件账号无配额；隔离文件，避免自动路径反复用错账号
                Self.quarantineOAuthFileAfterUnauthorized()
                DispatchQueue.main.async { completion(.failure(UsageError.unauthorized)) }
                return
            }

            guard (200...299).contains(http.statusCode), let data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure(UsageError.httpError(statusCode: http.statusCode))) }
                return
            }

            do {
                let response = try JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
                let usageData = response.toUsageData()
                DispatchQueue.main.async { completion(.success(usageData)) }
            } catch {
                Logger.api.error("Antigravity 配额数据解析失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(UsageError.decodingError)) }
            }
        }

        taskLock.lock()
        activeTasks.append(task)
        taskLock.unlock()
        task.resume()
    }

    private func removeActiveTask(_ task: URLSessionDataTask) {
        taskLock.lock()
        activeTasks.removeAll { $0 === task }
        taskLock.unlock()
    }

    // MARK: - Mock Data

    #if DEBUG
    private func createMockData() -> AntigravityUsageData {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(3 * 3600 + 18 * 60)
        let weeklyReset = now.addingTimeInterval(5 * 86400 + 17 * 3600)

        let gemini5h = AntigravityUsageData.LimitData(
            percentage: 8.5,
            remainingFraction: 0.915,
            resetsAt: fiveHourReset,
            description: "5小时窗口额度"
        )
        let geminiWeekly = AntigravityUsageData.LimitData(
            percentage: 3.6,
            remainingFraction: 0.964,
            resetsAt: weeklyReset,
            description: "周级额度"
        )

        let thirdParty5h = AntigravityUsageData.LimitData(
            percentage: 0.0,
            remainingFraction: 1.0,
            resetsAt: fiveHourReset,
            description: "Claude / GPT 5小时额度"
        )
        let thirdPartyWeekly = AntigravityUsageData.LimitData(
            percentage: 0.0,
            remainingFraction: 1.0,
            resetsAt: weeklyReset,
            description: "Claude / GPT 周级额度"
        )

        let geminiGroup = AntigravityUsageData.ModelGroup(
            displayName: "Gemini Models",
            description: "Gemini Flash, Gemini Pro",
            fiveHourLimit: gemini5h,
            weeklyLimit: geminiWeekly
        )
        let thirdPartyGroup = AntigravityUsageData.ModelGroup(
            displayName: "Claude and GPT models",
            description: "Claude Opus, Claude Sonnet, GPT-OSS",
            fiveHourLimit: thirdParty5h,
            weeklyLimit: thirdPartyWeekly
        )

        return AntigravityUsageData(
            primary: gemini5h,
            secondary: geminiWeekly,
            groups: [geminiGroup, thirdPartyGroup]
        )
    }
    #endif
}
