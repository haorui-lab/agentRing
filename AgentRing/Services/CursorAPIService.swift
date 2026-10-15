//
//  CursorAPIService.swift
//  Agent Ring
//

import Foundation
import OSLog

class CursorAPIService: UsageProvider {
    var providerType: ProviderType { .cursor }

    private let settings = UserSettings.shared
    private let session: URLSession
    private var activeTasks: [URLSessionDataTask] = []

    private let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func cancelAllRequests() {
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    func fetchUsage(completion: @escaping (Result<CursorUsageData, Error>) -> Void) {
        #if DEBUG
        if settings.debugModeEnabled {
            DispatchQueue.main.async { completion(.success(self.createMockData())) }
            return
        }
        #endif

        cancelAllRequests()

        guard settings.hasValidCursorCredentials else {
            completion(.failure(UsageError.noCredentials))
            return
        }

        let token = settings.cursorSessionToken
        fetchDashboardUsage(sessionToken: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let usage):
                completion(.success(usage))
            case .failure(let error):
                Logger.api.info(
                    "Cursor dashboard usage unavailable (\(error.localizedDescription, privacy: .public)); falling back to usage-summary"
                )
                self.fetchUsageSummary(sessionToken: token, completion: completion)
            }
        }
    }

    func validateSessionToken(_ sessionToken: String, completion: @escaping (Result<CursorAuthMeResponse, Error>) -> Void) {
        guard let url = URL(string: "https://cursor.com/api/auth/me") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        applyCursorHeaders(to: &request, sessionToken: sessionToken)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(UsageError.networkError))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(UsageError.unauthorized))
                return
            }
            guard (200...299).contains(http.statusCode), let data, !data.isEmpty else {
                completion(.failure(UsageError.httpError(statusCode: http.statusCode)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(CursorAuthMeResponse.self, from: data)
                completion(.success(decoded))
            } catch {
                Logger.api.error("Cursor auth/me 解码失败: \(error.localizedDescription)")
                completion(.failure(UsageError.decodingError))
            }
        }
        activeTasks.append(task)
        task.resume()
    }

    /// Prefer live dashboard period + plan-info (weekly X Subscription). Falls back to usage-summary on failure.
    private func fetchDashboardUsage(sessionToken: String, completion: @escaping (Result<CursorUsageData, Error>) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var periodResult: Result<CursorCurrentPeriodUsageResponse, Error>?
        var planResult: Result<CursorPlanInfoResponse, Error>?

        group.enter()
        postDashboardJSON(
            path: "/api/dashboard/get-current-period-usage",
            sessionToken: sessionToken
        ) { (result: Result<CursorCurrentPeriodUsageResponse, Error>) in
            lock.lock()
            periodResult = result
            lock.unlock()
            group.leave()
        }

        group.enter()
        postDashboardJSON(
            path: "/api/dashboard/get-plan-info",
            sessionToken: sessionToken
        ) { (result: Result<CursorPlanInfoResponse, Error>) in
            lock.lock()
            planResult = result
            lock.unlock()
            group.leave()
        }

        group.notify(queue: .main) {
            guard let periodResult else {
                completion(.failure(UsageError.networkError))
                return
            }
            switch periodResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let period):
                guard period.isUsableForMapping else {
                    completion(.failure(UsageError.decodingError))
                    return
                }
                let plan: CursorPlanInfoResponse?
                switch planResult {
                case .success(let value):
                    plan = value
                case .failure, .none:
                    plan = nil
                }
                let usage = CursorUsageMapper.map(period: period, plan: plan)
                completion(.success(usage))
            }
        }
    }

    private func postDashboardJSON<T: Decodable>(
        path: String,
        sessionToken: String,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        guard let url = URL(string: "https://cursor.com\(path)") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        applyCursorHeaders(to: &request, sessionToken: sessionToken)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(UsageError.networkError))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(UsageError.unauthorized))
                return
            }
            if http.statusCode == 429 {
                completion(.failure(UsageError.rateLimited))
                return
            }
            guard (200...299).contains(http.statusCode), let data, !data.isEmpty else {
                completion(.failure(UsageError.httpError(statusCode: http.statusCode)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                Logger.api.error("Cursor \(path, privacy: .public) 解码失败: \(error.localizedDescription)")
                completion(.failure(UsageError.decodingError))
            }
        }
        activeTasks.append(task)
        task.resume()
    }

    private func fetchUsageSummary(sessionToken: String, completion: @escaping (Result<CursorUsageData, Error>) -> Void) {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        applyCursorHeaders(to: &request, sessionToken: sessionToken)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(UsageError.networkError)) }
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                DispatchQueue.main.async { completion(.failure(UsageError.unauthorized)) }
                return
            }
            if http.statusCode == 429 {
                DispatchQueue.main.async { completion(.failure(UsageError.rateLimited)) }
                return
            }
            guard (200...299).contains(http.statusCode), let data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure(UsageError.httpError(statusCode: http.statusCode))) }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
                let usage = decoded.toUsageData()
                DispatchQueue.main.async { completion(.success(usage)) }
            } catch {
                Logger.api.error("Cursor usage-summary 解码失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(UsageError.decodingError)) }
            }
        }
        activeTasks.append(task)
        task.resume()
    }

    private func applyCursorHeaders(to request: inout URLRequest, sessionToken: String) {
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(safariUserAgent, forHTTPHeaderField: "user-agent")
        request.setValue("https://cursor.com", forHTTPHeaderField: "origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "referer")
        request.setValue("WorkosCursorSessionToken=\(sessionToken)", forHTTPHeaderField: "Cookie")
    }

    #if DEBUG
    private func createMockData() -> CursorUsageData {
        let included = settings.debugCursorIncludedPercentage
        let onDemandEnabled = settings.debugCursorOnDemandLimit > 0
        let cycleEnd = Date().addingTimeInterval(60 * 60 * 24 * 12)
        let secondaryPool = CursorUsageData.LimitData(
            percentage: min(100, max(0, included * 0.2)),
            resetsAt: cycleEnd,
            used: nil,
            limit: nil
        )
        let onDemandPool: CursorUsageData.OnDemandData? = onDemandEnabled ? .init(
            percentage: settings.debugCursorOnDemandPercentage,
            usedCents: settings.debugCursorOnDemandPercentage / 100.0 * settings.debugCursorOnDemandLimit,
            limitCents: settings.debugCursorOnDemandLimit,
            resetsAt: cycleEnd
        ) : nil
        return CursorUsageData(
            included: .init(
                percentage: included,
                resetsAt: cycleEnd,
                used: included,
                limit: 100
            ),
            secondary: secondaryPool,
            onDemand: onDemandPool,
            membershipType: "pro",
            billingCycleEnd: cycleEnd,
            presentation: CursorPresentation(
                cadence: .monthly,
                membershipDisplayName: "Pro",
                includedLabelKey: CursorPresentationBuilder.LabelKey.includedLegacy,
                secondaryLabelKey: CursorPresentationBuilder.LabelKey.secondaryApiModels,
                secondaryKind: .apiModels,
                onDemandLabelKey: onDemandPool != nil ? CursorPresentationBuilder.LabelKey.onDemandSpend : nil,
                billingMode: .legacyCursor
            ),
            fetchSource: .debugMock
        )
    }
    #endif
}
