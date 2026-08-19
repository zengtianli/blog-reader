// 离线可读的实证 —— 打的是**真的 Sources/Store.swift**（编译时一起传进来），
// 用一个「任何请求都失败」的 URLSession 顶掉网络。
// 不这么测的话，「代码里第一句就读缓存」只是读代码推理，按铁律 #2 不算验证。
import Foundation

final class AlwaysFail: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError:
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    }
    override func stopLoading() {}
}

func deadSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [AlwaysFail.self]
    return URLSession(configuration: c)
}

@MainActor
func runOffline() async -> Int {
    var fails: [String] = []
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("blogreader-offline-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = Store(session: deadSession(), baseDir: tmp)
    let cacheDir = tmp.appendingPathComponent("blog-reader")

    let cached = FeedPost(slug: "two-report-cards", lang: "zh", title: "缓存过的",
                          date: "2026-08-18", url: "https://x/", siteKey: "options")
    let never  = FeedPost(slug: "never-fetched", lang: "zh", title: "没缓存过的",
                          date: "2026-08-18", url: "https://x/", siteKey: "options")

    // 手动种一篇缓存（模拟「联网时读过它」）
    let seeded = #"""
    {"slug":"two-report-cards","locale":"zh","title":"跑赢大盘的那天","date":"2026-08-18",
     "url":"https://blog-options.tianli.cyou/two-report-cards","markdown":"# 标题\n\n正文**加粗**。"}
    """#
    try? seeded.data(using: .utf8)!.write(
        to: cacheDir.appendingPathComponent("post-options-two-report-cards-zh.json"))

    // ① 缓存命中：网络全死，仍应读到正文
    switch await store.body(for: cached) {
    case .success(let d):
        if d.title != "跑赢大盘的那天" { fails.append("①标题错: \(d.title)") }
        if !d.markdown.contains("正文**加粗**") { fails.append("①正文错") }
    case .failure(let e):
        fails.append("①网络全死时读缓存**失败**了: \(e.message)")
    }

    // ② 没缓存过的：应当失败，且理由要说人话（而不是抛异常或返回空正文）
    switch await store.body(for: never) {
    case .success:
        fails.append("②没缓存过的竟然成功了 —— 说明缓存键没区分 slug")
    case .failure(let e):
        if !e.message.contains("离线") { fails.append("②失败文案没提离线: \(e.message)") }
    }

    // ③ 索引：三站全拉不到时，posts 不该被清空（此处没种索引缓存，应为空但不崩）
    await store.refresh()
    if store.refreshError == nil { fails.append("③三站全失败却没挂错误条") }
    if !store.posts.isEmpty { fails.append("③凭空多出文章") }

    // ④ isCached 查的是文件在不在，不是猜的
    if !store.isCached(cached) { fails.append("④已种缓存却报未缓存") }
    if store.isCached(never)   { fails.append("④没缓存的报成已缓存") }

    if fails.isEmpty {
        print("✅ 离线 4 条全过：缓存命中 / 未缓存有说人话的失败 / 全网失败不清空 / isCached 查真文件")
        return 0
    }
    print("❌ 离线测试 \(fails.count) 条不过：")
    fails.forEach { print("   " + $0) }
    return 1
}

@main
struct OfflineTest {
    static func main() async {
        exit(Int32(await runOffline()))
    }
}
