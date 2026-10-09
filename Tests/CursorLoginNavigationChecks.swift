import Foundation

// Cursor 登录入口与 WorkOS GET-only 路由判断。
// 用法：swiftc CursorLoginNavigation.swift 本文件 && 运行

@main
struct CursorLoginNavigationChecks {
    static func main() {
        func expect(_ condition: Bool, _ name: String) {
            if !condition {
                print("FAIL: \(name)")
                exit(1)
            }
            print("PASS: \(name)")
        }

        expect(
            CursorLoginNavigation.startURLString == "https://cursor.com/api/auth/login",
            "login starts at cursor.com/api/auth/login"
        )
        let start = CursorLoginNavigation.startURL
        expect(start?.host == "cursor.com", "start host is cursor.com")
        expect(start?.path == "/api/auth/login", "start path is /api/auth/login")
        expect(start?.query == nil, "start URL does not pin an empty context")

        let initiate = URL(string: "https://authenticate.cursor.sh/user_management/initiate_login?context=&client_id=client_01GS6W3C96KW4WRS6Z93JCE2RJ")!
        expect(
            CursorLoginNavigation.shouldReplayAsFreshLogin(method: "POST", url: initiate),
            "POST initiate_login with empty context is a trap"
        )
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: "GET", url: initiate),
            "GET initiate_login is the working recovery redirect"
        )
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: "HEAD", url: initiate),
            "HEAD initiate_login is not replayed"
        )
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: nil, url: initiate),
            "missing method is treated as GET"
        )
        expect(
            CursorLoginNavigation.isUnusableAuthDocument(initiate),
            "initiate_login document is not a login form"
        )

        let authorize = URL(string: "https://api.workos.com/user_management/authorize?client_id=client_01GS6W3C96KW4WRS6Z93JCE2RJ&provider=authkit&response_type=code")!
        expect(
            CursorLoginNavigation.shouldReplayAsFreshLogin(method: "post", url: authorize),
            "POST authorize is a trap regardless of method casing"
        )
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: "GET", url: authorize),
            "GET authorize is the normal login redirect"
        )

        let loginPage = URL(string: "https://authenticator.cursor.sh/?client_id=client_01GS6W3C96KW4WRS6Z93JCE2RJ&authorization_session_id=01M4FQMSZV400DNA2MPPAZV6J0")!
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: "POST", url: loginPage),
            "POST to the session login page is left alone"
        )
        expect(!CursorLoginNavigation.isUnusableAuthDocument(loginPage), "session login page is usable")

        let elsewhere = URL(string: "https://example.com/user_management/initiate_login")!
        expect(
            !CursorLoginNavigation.shouldReplayAsFreshLogin(method: "POST", url: elsewhere),
            "same path on an unrelated host is not rewritten"
        )

        let slashed = URL(string: "https://authenticate.cursor.sh/user_management/initiate_login/")!
        expect(
            CursorLoginNavigation.isUnusableAuthDocument(slashed),
            "trailing slash still matches the trap path"
        )
    }
}
