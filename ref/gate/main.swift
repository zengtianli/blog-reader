import Foundation

// 真打公网，验三件事（缺一条这套机制就是赌的）：
//   ① 没 cookie 时 Gate.blocked() 认得出来（URLSession 跟完 302 后是 200，状态码分辨不出）
//   ② cookie 放进 URLSession 的 cookie jar 后，**自动带到子域** blog-options
//   ③ 带上之后 feed 真解析得出文章
// cookie 从 VPS 上用 TLZ_GATE_SECRET 现签一枚（不需要知道密码）。

let ck = ProcessInfo.processInfo.environment["PROBE_COOKIE"] ?? ""
guard !ck.isEmpty else { print("❌ 没给 PROBE_COOKIE"); exit(2) }

let site = Site.all.first { $0.key == "options" }!
var fails = 0
func ck_(_ what: String, _ ok: Bool, _ why: String = "") {
    print((ok ? "  ✅ " : "  ❌ ") + what + (ok ? "" : "  —— " + why))
    if !ok { fails += 1 }
}

// ⚠ 必须用 HTTPCookieStorage.shared。
//   `HTTPCookieStorage()` 这个 init 出来的实例是个**哑对象**：setCookie 进去
//   `cookies` 仍是 0 枚、cookies(for:) 永远返回空 —— 2026-08-28 实测。
//   第一版探针就栽在这，报出「跨子域这条路走不通」这个**假的结论**，
//   差点据此把整套设计推翻重做。测试工具本身出错时，长得跟被测系统出错一模一样。
let jar = HTTPCookieStorage.shared
for c in jar.cookies ?? [] where c.name == "tlz_gate" { jar.deleteCookie(c) }
let cfg = URLSessionConfiguration.default
cfg.httpCookieStorage = jar
cfg.httpShouldSetCookies = true
let session = URLSession(configuration: cfg)

func fetch() async -> (Data, URLResponse) {
    var r = URLRequest(url: site.feedURL)
    r.cachePolicy = .reloadIgnoringLocalCacheData
    return try! await session.data(for: r)
}

let sem = DispatchSemaphore(value: 0)
Task {
    print("【① 没 cookie】")
    var (data, resp) = await fetch()
    ck_("Gate.blocked() 认出被拦", Gate.blocked(resp),
        "最终 URL = \(resp.url?.absoluteString ?? "?")")
    ck_("状态码分辨不出来（所以判据不能用它）",
        (resp as? HTTPURLResponse)?.statusCode == 200,
        "实际 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
    ck_("此时 feed 解析必然失败", (try? FeedParse.feed(data, siteKey: "options")) == nil)

    print("【② 把 cookie 放进 jar（模拟服务端 Set-Cookie 的效果）】")
    // 用 Foundation **自己的解析器**吃服务端那行真 Set-Cookie，
    // 而不是手工 new 一个 HTTPCookie —— 后者测的是我的构造方式，不是真链路。
    let hdr = ["Set-Cookie":
        "tlz_gate=\(ck); Domain=.tianli.cyou; Path=/; Max-Age=604800; HttpOnly; Secure; SameSite=lax"]
    let parsed = HTTPCookie.cookies(withResponseHeaderFields: hdr,
                                    for: Gate.loginURL)
    ck_("Foundation 解析出 1 枚 cookie", parsed.count == 1, "解析出 \(parsed.count) 枚")
    parsed.forEach(jar.setCookie)
    ck_("jar 里认为该发给 blog-options 子域",
        (jar.cookies(for: site.feedURL) ?? []).contains { $0.name == "tlz_gate" },
        "cookie 域是 .tianli.cyou，子域拿不到就说明跨子域这条路走不通")

    print("【③ 带 cookie 重取】")
    (data, resp) = await fetch()
    ck_("不再被闸拦", !Gate.blocked(resp), "最终 URL = \(resp.url?.absoluteString ?? "?")")
    if let f = try? FeedParse.feed(data, siteKey: "options") {
        ck_("解析出文章（\(f.posts.count) 条）", f.posts.count > 0)
        print("      最新一篇：\(f.posts.first?.date ?? "") \(f.posts.first?.title.prefix(40) ?? "")")
    } else {
        ck_("解析出文章", false, "带了 cookie 仍解析不出")
    }
    sem.signal()
}
sem.wait()
print(fails == 0 ? "\n✅ 三段全过" : "\n❌ \(fails) 条没过")
exit(fails == 0 ? 0 : 2)
