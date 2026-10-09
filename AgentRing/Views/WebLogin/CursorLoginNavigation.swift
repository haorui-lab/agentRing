//
//  CursorLoginNavigation.swift
//  Agent Ring
//

import Foundation

/// Cursor 网页登录的入口，以及 WorkOS 上不能当作文档打开的路由。
///
/// 裸开 `https://authenticator.cursor.sh/` 会 307 到
/// `/user_management/initiate_login?context=&client_id=...`（context 为空，因为没有 authorization session）。
/// 307 保留 HTTP 方法。这条路由只实现了 GET：GET 会 302 到 `cursor.com/api/auth/login`，
/// POST 则是 Express 404，正文就是用户看到的
/// `{"message":"Cannot POST /user_management/initiate_login?...","error":"Not Found"}`。
/// `POST /user_management/authorize` 同样 404。
///
/// 正确入口是 `https://cursor.com/api/auth/login`。它会签发 authorization session，
/// 最终落到带 `authorization_session_id` 的 AuthKit 页面；该页面的 GET 和 POST 都返回登录 HTML。
enum CursorLoginNavigation {
    static let startURLString = "https://cursor.com/api/auth/login"
    static let maxRecoveries = 2

    static var startURL: URL? {
        URL(string: startURLString)
    }

    /// 非 GET/HEAD 打到只实现了 GET 的 WorkOS 路由。跟随这种跳转会把 404 JSON 显示成登录页。
    static func shouldReplayAsFreshLogin(method: String?, url: URL) -> Bool {
        let normalized = (method ?? "GET").uppercased()
        guard normalized != "GET", normalized != "HEAD" else { return false }
        return isUnusableAuthDocument(url: url)
    }

    /// 主框架如果停在这些路径上，文档就是授权跳转或 404，不是登录表单。
    static func isUnusableAuthDocument(url: URL) -> Bool {
        guard isCursorAuthHost(url.host) else { return false }
        switch normalizedPath(url.path) {
        case "/user_management/initiate_login", "/user_management/authorize":
            return true
        default:
            return false
        }
    }

    private static func isCursorAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "cursor.com" || host.hasSuffix(".cursor.com") { return true }
        if host == "cursor.sh" || host.hasSuffix(".cursor.sh") { return true }
        if host == "workos.com" || host.hasSuffix(".workos.com") { return true }
        return false
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
