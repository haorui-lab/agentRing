import Foundation

// Antigravity account-identity helpers: id_token email parsing + switch detection.
// Invoked from AntigravityQuotaMapperChecks (single @main entry).

enum AntigravityAccountIdentityChecks {
    static func runAll() {
        checkEmailFromIDToken()
        checkEmailFallbackToSub()
        checkDidSwitch()
        checkUsageDataAccountStamp()
    }

    // MARK: - JWT email

    static func checkEmailFromIDToken() {
        let token = fakeJWT(payload: ["email": "alice@gmail.com", "sub": "123"])
        expect(
            AntigravityAccountIdentity.email(fromIDToken: token) == "alice@gmail.com",
            "id_token email claim parsed"
        )
        expect(
            AntigravityAccountIdentity.email(fromIDToken: "not-a-jwt") == nil,
            "invalid token → nil"
        )
        expect(
            AntigravityAccountIdentity.email(fromIDToken: "") == nil,
            "empty token → nil"
        )
    }

    static func checkEmailFallbackToSub() {
        let token = fakeJWT(payload: ["sub": "google-sub-99"])
        expect(
            AntigravityAccountIdentity.email(fromIDToken: token) == "google-sub-99",
            "missing email falls back to sub"
        )
        let blankEmail = fakeJWT(payload: ["email": "  ", "sub": "sub-only"])
        expect(
            AntigravityAccountIdentity.email(fromIDToken: blankEmail) == "sub-only",
            "whitespace email falls back to sub"
        )
    }

    static func checkDidSwitch() {
        expect(
            !AntigravityAccountIdentity.didSwitch(from: nil, to: "a@b.com"),
            "nil → email is not a switch (first paint)"
        )
        expect(
            !AntigravityAccountIdentity.didSwitch(from: "a@b.com", to: nil),
            "email → nil is not a switch"
        )
        expect(
            !AntigravityAccountIdentity.didSwitch(from: "a@b.com", to: "A@B.com"),
            "case-insensitive same email is not a switch"
        )
        expect(
            AntigravityAccountIdentity.didSwitch(from: "old@gmail.com", to: "new@gmail.com"),
            "different emails are a switch — multi-account root cause guard"
        )
    }

    static func checkUsageDataAccountStamp() {
        let group = AntigravityQuotaResponse.GroupResponse(
            displayName: "Gemini Models",
            description: nil,
            buckets: [
                AntigravityQuotaResponse.BucketResponse(
                    bucketId: "gemini-5h",
                    displayName: "Five Hour Limit Remaining",
                    description: nil,
                    window: "5h",
                    remainingFraction: 0.5,
                    resetTime: nil
                )
            ]
        )
        let response = AntigravityQuotaResponse(groups: [group], description: nil, response: nil)
        let stamped = response.toUsageData(accountEmail: "bob@gmail.com")
        expect(stamped.accountEmail == "bob@gmail.com", "toUsageData stamps accountEmail")
        expect(stamped.primary?.remainingFraction == 0.5, "stamped usage still maps quota")

        let relabeled = stamped.withAccountEmail("carol@gmail.com")
        expect(relabeled.accountEmail == "carol@gmail.com", "withAccountEmail replaces identity")
        expect(relabeled.primary?.remainingFraction == 0.5, "withAccountEmail keeps quota numbers")
        expect(
            AntigravityAccountIdentity.didSwitch(from: stamped.accountEmail, to: relabeled.accountEmail),
            "stamped → relabeled detected as account switch"
        )
    }

    // MARK: - Helpers

    static func fakeJWT(payload: [String: Any]) -> String {
        let header = base64URL(["alg": "none", "typ": "JWT"])
        let body = base64URL(payload)
        return "\(header).\(body).sig"
    }

    static func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS: \(label)")
        } else {
            print("FAIL: \(label)")
            exit(1)
        }
    }
}
