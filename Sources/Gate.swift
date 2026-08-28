import Foundation
import Security

// =============================================================================
// 站群访问闸（authgate）的客户端。
//
// 为什么需要它：`blog-options`（投资日复盘）**整站**挂着 authgate ——
// 2026-08-21 用户钦定「整站 authgate(location / 带 protect)，不进任何导航」。
// 于是这个 app 取它的 feed 时拿到的是 302 → 登录页的 **200 HTML**，
// 解析失败，那个站静默贡献 0 篇；错误条上只有一句「options: 解析失败」，
// 既不像错误、也指不出方向。实测那天该站有 82 篇文章，一篇都没进来。
//
// 2026-08-28 用户钦定：「我的期权文章也要放到「我的文章」这个 app 里，
// **这个 app 就我自用**」—— 授权这个私人客户端带凭证读受闸站。
//
// ⚠ **不是**在闸上给 /feed.json 开洞。那会让期权文章对全网公开，
//   而闸正是用户自己要的。客户端拿凭证 ≠ 内容变公开，这两件事别混。
//
// 凭证保管三条：
//   ① 密码只进 **Keychain**，不进仓库、不进 UserDefaults、不进任何 plist。
//   ② 存的是**密码**不是 cookie：cookie 只有 7 天（服务端 API_SESSION_DAYS，
//      因为它对小程序那种明文 storage 客户端也发），存密码才能自动续。
//   ③ 会话 cookie 交给 URLSession 自己的 cookie jar 管（HttpOnly + Secure 语义
//      保持完整）。服务端那条「顺手也下发标准 Set-Cookie」就是给我们用的。
// =============================================================================

enum Gate {
    /// 闸的对外前缀。服务端 SSOT 是 `gate.URL_PREFIX`，两边都是 `/_gate`。
    static let prefix = "/_gate"
    static let loginURL = URL(string: "https://tianli.cyou\(prefix)/api/login")!

    /// 这次响应是不是被闸拦下来了。
    ///
    /// **判据是最终 URL 落在 `/_gate/` 下**，不是状态码、也不是 HTML 里有什么字：
    /// URLSession 默认会跟 302，所以到手的是登录页的 200，状态码分辨不出来；
    /// 而嗅 HTML 内容是在给页面文案建第二份判据，改个字就瞎。
    static func blocked(_ resp: URLResponse?) -> Bool {
        (resp?.url?.path ?? "").hasPrefix(prefix + "/")
    }

    // MARK: - 凭证（Keychain）

    private static let service = "cyou.tianli.blogreader.gate"
    private static let account = "password"

    static var hasPassword: Bool { password != nil }

    static var password: String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func savePassword(_ pw: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(pw.utf8),
            // AfterFirstUnlock：开机后第一次解锁起就可读，让后台刷新也能自动续会话。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { a, _ in a }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func forgetPassword() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    // MARK: - 登录

    struct Failure: Error { let message: String }

    /// 拿密码换一次会话。成功后 cookie 落进 `session` 的 cookie jar，
    /// 域是 `.tianli.cyou`，之后所有子域请求自动带上。
    ///
    /// 服务端返回体形如 `{"ok":true,"cookie_name":"tlz_gate","cookie":"v1...."}`；
    /// **我们只看 `ok`，不碰 `cookie` 字段** —— 那个字段是给没有 cookie jar 的
    /// 客户端（小程序）用的，把它取出来自己存等于把凭证从 HttpOnly 壳里搬出来，
    /// 白白扩大失窃半径。
    static func login(password pw: String, session: URLSession) async throws {
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "password", value: pw)]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // 服务端的原话比「登录失败」有用：密码错是「密码不对。」，
        // 撞限流是「尝试过于频繁，请 N 秒后再试。」——后者重试解决不了，得让人看见。
        let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 200, said?["ok"] as? Bool == true { return }
        throw Failure(message: (said?["error"] as? String) ?? "登录失败（HTTP \(code)）")
    }
}
