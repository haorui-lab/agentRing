//
//  AntigravityDiagnosticRunner.swift
//  Agent Ring
//

import Foundation

@MainActor
final class AntigravityDiagnosticRunner: DiagnosticRunner {

    let providerType: ProviderType = .antigravity
    private let settings = UserSettings.shared
    private let cloudEndpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

    func run() async -> ProviderDiagnosticResult {
        guard settings.antigravityEnabled else {
            return ProviderDiagnosticResult(
                providerType: .antigravity,
                credentials: ["Monitoring": "Disabled"],
                steps: [],
                success: false,
                errorType: .invalidCredentials,
                diagnosis: DiagnosticMessage.diagnosisAntigravityDisabled,
                suggestions: [DiagnosticMessage.suggestionAntigravityEnable],
                confidence: .high
            )
        }

        AntigravityAPIService.invalidateCredentialsCache()
        guard let token = await resolveTokenOffMainThread() else {
            return ProviderDiagnosticResult(
                providerType: .antigravity,
                credentials: [
                    "Keychain (gemini/antigravity)": "Not found",
                    "File (~/.gemini/oauth_creds.json)": "Not found or expired"
                ],
                steps: [],
                success: false,
                errorType: .invalidCredentials,
                diagnosis: DiagnosticMessage.diagnosisAntigravityNoCredentials,
                suggestions: [
                    DiagnosticMessage.suggestionAntigravityOpenApp,
                    DiagnosticMessage.suggestionAntigravityEnable
                ],
                confidence: .high
            )
        }

        let credentials: [String: String] = [
            "Access Token": SensitiveDataRedactor.redactAccessToken(token),
            "Monitoring": settings.antigravityEnabled ? "Enabled" : "Disabled"
        ]

        let quotaStep = await runQuotaStep(token: token)
        let success = quotaStep.success
        let (diagnosis, suggestions, confidence) = diagnose(step: quotaStep)

        return ProviderDiagnosticResult(
            providerType: .antigravity,
            credentials: credentials,
            steps: [quotaStep],
            success: success,
            errorType: success ? nil : (quotaStep.errorType ?? .unknown),
            diagnosis: diagnosis,
            suggestions: suggestions,
            confidence: confidence
        )
    }

    private func resolveTokenOffMainThread() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: AntigravityAPIService.resolveAccessToken(allowInteractiveKeychain: true))
            }
        }
    }

    private func runQuotaStep(token: String) async -> DiagnosticStep {
        let stepName = "Quota Summary API"
        guard let url = URL(string: cloudEndpoint) else {
            return DiagnosticStep(
                name: stepName, success: false,
                httpStatusCode: nil, responseTime: 0,
                responseType: .unknown, errorType: .networkError,
                errorDescription: "Invalid quota endpoint URL",
                responseHeaders: [:], responseBodyPreview: nil,
                cloudflareChallenge: false, cfMitigated: false, notes: nil
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/1.2.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = "{}".data(using: .utf8)

        let startTime = Date()
        let session = URLSession(configuration: .ephemeral)

        do {
            let (data, response) = try await session.data(for: request)
            let responseTime = Date().timeIntervalSince(startTime) * 1000
            guard let http = response as? HTTPURLResponse else {
                return DiagnosticStep(
                    name: stepName, success: false,
                    httpStatusCode: nil, responseTime: responseTime,
                    responseType: .unknown, errorType: .unknown,
                    errorDescription: "Unknown response format",
                    responseHeaders: [:],
                    responseBodyPreview: String(data: data, encoding: .utf8).map { String($0.prefix(500)) },
                    cloudflareChallenge: false, cfMitigated: false, notes: nil
                )
            }

            let headers = extractSafeHeaders(from: http)
            if http.statusCode == 401 || http.statusCode == 403 {
                return DiagnosticStep(
                    name: stepName, success: false,
                    httpStatusCode: http.statusCode, responseTime: responseTime,
                    responseType: .unknown, errorType: .accessTokenExpired,
                    errorDescription: "Quota endpoint rejected the access token (HTTP \(http.statusCode))",
                    responseHeaders: headers, responseBodyPreview: nil,
                    cloudflareChallenge: false, cfMitigated: false,
                    notes: "Open Antigravity and sign in again so Keychain can refresh the token"
                )
            }

            guard (200..<300).contains(http.statusCode) else {
                return DiagnosticStep(
                    name: stepName, success: false,
                    httpStatusCode: http.statusCode, responseTime: responseTime,
                    responseType: .unknown, errorType: .usageEndpointFailed,
                    errorDescription: "Quota endpoint failed (HTTP \(http.statusCode))",
                    responseHeaders: headers,
                    responseBodyPreview: String(data: data, encoding: .utf8).map { String($0.prefix(500)) },
                    cloudflareChallenge: false, cfMitigated: false, notes: nil
                )
            }

            do {
                let decoded = try JSONDecoder().decode(AntigravityQuotaResponse.self, from: data)
                let usage = decoded.toUsageData()
                let groupCount = usage.groups.count
                let gemini5hPct = usage.geminiPrimary.map { String(format: "%.1f%%", $0.percentage) } ?? "n/a"
                let geminiWkPct = usage.geminiSecondary.map { String(format: "%.1f%%", $0.percentage) } ?? "n/a"
                let tp5hPct = usage.thirdPartyPrimary.map { String(format: "%.1f%%", $0.percentage) } ?? "n/a"
                let tpWkPct = usage.thirdPartySecondary.map { String(format: "%.1f%%", $0.percentage) } ?? "n/a"
                return DiagnosticStep(
                    name: stepName, success: true,
                    httpStatusCode: http.statusCode, responseTime: responseTime,
                    responseType: .json, errorType: nil, errorDescription: nil,
                    responseHeaders: headers,
                    responseBodyPreview: "Quota OK — groups=\(groupCount), gemini=\(gemini5hPct)/\(geminiWkPct), thirdParty=\(tp5hPct)/\(tpWkPct)",
                    cloudflareChallenge: false, cfMitigated: false,
                    notes: groupCount == 0 ? "Response parsed but contained no groups" : nil
                )
            } catch {
                return DiagnosticStep(
                    name: stepName, success: false,
                    httpStatusCode: http.statusCode, responseTime: responseTime,
                    responseType: .unknown, errorType: .decodingError,
                    errorDescription: "Quota response could not be parsed: \(error.localizedDescription)",
                    responseHeaders: headers,
                    responseBodyPreview: String(data: data, encoding: .utf8).map { String($0.prefix(500)) },
                    cloudflareChallenge: false, cfMitigated: false, notes: nil
                )
            }
        } catch {
            let responseTime = Date().timeIntervalSince(startTime) * 1000
            return DiagnosticStep(
                name: stepName, success: false,
                httpStatusCode: nil, responseTime: responseTime,
                responseType: .unknown, errorType: .networkError,
                errorDescription: error.localizedDescription,
                responseHeaders: [:], responseBodyPreview: nil,
                cloudflareChallenge: false, cfMitigated: false, notes: nil
            )
        }
    }

    private func diagnose(step: DiagnosticStep) -> (String, [String], ProviderDiagnosticResult.ConfidenceLevel) {
        if step.success {
            return (DiagnosticMessage.diagnosisAntigravitySuccess, [DiagnosticMessage.suggestionSuccess], .high)
        }
        switch step.errorType {
        case .accessTokenExpired:
            return (DiagnosticMessage.diagnosisAntigravityUnauthorized, [
                DiagnosticMessage.suggestionAntigravityOpenApp,
                DiagnosticMessage.suggestionRetryLater
            ], .high)
        case .networkError:
            return (DiagnosticMessage.diagnosisNetwork, [
                DiagnosticMessage.suggestionCheckInternet,
                DiagnosticMessage.suggestionCheckFirewall
            ], .high)
        case .decodingError:
            return (DiagnosticMessage.diagnosisDecoding, [
                DiagnosticMessage.suggestionExportAndShare,
                DiagnosticMessage.suggestionRetryLater
            ], .medium)
        default:
            return (DiagnosticMessage.diagnosisUnknown, [
                DiagnosticMessage.suggestionExportAndShare,
                DiagnosticMessage.suggestionContactSupport
            ], .low)
        }
    }

    private func extractSafeHeaders(from response: HTTPURLResponse) -> [String: String] {
        let allowedHeaders = [
            "content-type", "content-length", "server", "date", "cache-control", "x-request-id"
        ]
        var safeHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let keyStr = (key as? String ?? "").lowercased()
            if allowedHeaders.contains(keyStr) {
                safeHeaders[keyStr] = value as? String ?? ""
            }
        }
        return safeHeaders
    }
}
