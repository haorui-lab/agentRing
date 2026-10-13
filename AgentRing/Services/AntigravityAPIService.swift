//
//  AntigravityAPIService.swift
//  Agent Ring
//

import Foundation
import Security
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
    private let userAgent = "antigravity/1.2.1"

    private static let credentialsCacheLock = NSLock()
    private static var credentialsCache: (available: Bool, checkedAt: Date)?
    private static let credentialsCacheTTL: TimeInterval = 120
    private static var credentialsRefreshScheduled = false

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
    /// - `forceRefresh: true`：同步探测（调用方必须已在后台队列，如 AuthSettingsView）。
    static func credentialsAvailable(forceRefresh: Bool = false) -> Bool {
        if forceRefresh {
            assert(!Thread.isMainThread, "Antigravity credentialsAvailable(forceRefresh:) must not run on the main thread")
            return refreshCredentialsCacheSync()
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
    private static func refreshCredentialsCacheSync() -> Bool {
        let available = resolveAccessToken() != nil
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
            guard let token = Self.resolveAccessToken() else {
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

    /// 依次从以下途径解析有效的 Access Token：
    /// 1. 本地 OAuth 文件（~/.gemini/oauth_creds.json）— 最快，不弹钥匙串权限
    /// 2. macOS 钥匙串（Service: "gemini", Account: "antigravity"）
    static func resolveAccessToken() -> String? {
        if let tokenFromFile = readTokenFromLocalFile() {
            return tokenFromFile
        }
        if let tokenFromKeychain = readTokenFromKeychain() {
            return tokenFromKeychain
        }
        return nil
    }

    private static func readTokenFromKeychain() -> String? {
        // 沙盒内 SecItem 往往读不到 Gemini/Antigravity 写入的通用密码；先试 API，再回退 CLI。
        // 调用方必须保证不在主线程（credentialsAvailable 默认路径 / fetchUsage 已避开）。
        if let viaSecItem = readTokenFromKeychainSecItem() {
            return viaSecItem
        }
        return readTokenFromKeychainSecurityCLI()
    }

    private static func readTokenFromKeychainSecItem() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            if status != errSecSuccess && status != errSecItemNotFound {
                Logger.api.debug("SecItemCopyMatching Antigravity 钥匙串失败: \(status)")
            }
            return nil
        }
        return parseKeychainSecret(raw)
    }

    private static func readTokenFromKeychainSecurityCLI() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let rawOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return parseKeychainSecret(rawOutput)
        } catch {
            Logger.api.debug("通过 security CLI 读取 Antigravity 钥匙串失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseKeychainSecret(_ raw: String) -> String? {
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            let b64 = String(raw.dropFirst(prefix.count))
            guard let jsonData = Data(base64Encoded: b64) else { return nil }
            struct Payload: Codable {
                struct Token: Codable {
                    let access_token: String?
                }
                let token: Token?
            }
            if let decoded = try? JSONDecoder().decode(Payload.self, from: jsonData) {
                return decoded.token?.access_token
            }
        }
        return raw.isEmpty ? nil : raw
    }

    private static func readTokenFromLocalFile() -> String? {
        let path = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        struct FileCreds: Codable {
            let access_token: String?
            let expiry_date: Double?
        }
        guard let creds = try? JSONDecoder().decode(FileCreds.self, from: data),
              let token = creds.access_token, !token.isEmpty else { return nil }

        if let expiry = creds.expiry_date {
            // 兼容秒级时间戳与毫秒级时间戳；缺字段则不据此拒绝
            let expirySeconds = expiry > 1_000_000_000_000 ? (expiry / 1000.0) : expiry
            if expirySeconds <= Date().timeIntervalSince1970 + 30 {
                Logger.api.debug("~/.gemini/oauth_creds.json 中的 token 已过期，跳过并尝试钥匙串")
                return nil
            }
        }
        return token
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
                Self.markCredentialsUnavailable()
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
