import Foundation

// =============================================================================
// 取数 + 缓存。**离线优先**：先把缓存吐出来渲染，再后台刷新；网络挂了就一直用缓存。
//
// 两段式，因为索引和正文的生命周期不同：
//   索引 feed.json  —— 每次开 app 刷。它小（12~65 KB/站），且要能立刻看到新文章。
//   正文 /api/post  —— 取到就**长期留着**。文章发布后基本不改，为读一篇旧文再联网
//                      一次是纯浪费；地铁里没信号也该能读。
//
// 缓存放 Application Support（不是 Caches）：Caches 目录 iOS 会在空间紧张时**自行清掉**，
// 那正好会把「离线能读」这个卖点在最需要它的时候拿走。
// =============================================================================

@MainActor
final class Store: ObservableObject {
    @Published private(set) var posts: [FeedPost] = []
    @Published private(set) var siteTitles: [String: String] = [:]   // key → 站名（来自 feed，不硬编码）
    @Published private(set) var loading = false
    /// nil = 正常；非 nil = 这次刷新没成功（此时 posts 仍是缓存内容，不清空）
    @Published private(set) var refreshError: String?
    /// 索引是不是缓存来的（离线时给用户一个诚实的提示，别让人以为看到的是最新的）
    @Published private(set) var isStale = false
    @Published private(set) var lastRefresh: Date?

    private let dir: URL
    private let session: URLSession

    /// `baseDir` 只为可测:回归要能塞一个临时目录进来,否则测试会写到真的
    /// Application Support 里去(既污染,又让「缓存命中」可能是上一次运行留下的假绿)。
    init(session: URLSession = .shared, baseDir: URL? = nil) {
        self.session = session
        let base = baseDir
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("blog-reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadCachedFeeds()
    }

    // MARK: - 索引

    private func feedCache(_ key: String) -> URL { dir.appendingPathComponent("feed-\(key).json") }

    /// 开 app 第一件事：把缓存渲染出来。**同步**做完，别先闪一屏空白再填。
    private func loadCachedFeeds() {
        var all: [Feed] = []
        for site in Site.all {
            guard let data = try? Data(contentsOf: feedCache(site.key)),
                  let f = try? FeedParse.feed(data, siteKey: site.key) else { continue }
            all.append(f)
        }
        guard !all.isEmpty else { return }
        apply(all, stale: true)
    }

    private func apply(_ feeds: [Feed], stale: Bool) {
        posts = FeedParse.merge(feeds)
        for f in feeds { siteTitles[f.site.key] = f.site.title }
        isStale = stale
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        var fresh: [Feed] = []
        var failures: [String] = []

        // 三站并发拉。串行的话最慢那个站决定整体等待时间，而它们互不依赖。
        await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            for site in Site.all {
                group.addTask { [session] in
                    do {
                        var req = URLRequest(url: site.feedURL)
                        req.timeoutInterval = 15
                        req.cachePolicy = .reloadIgnoringLocalCacheData   // 我们自己管缓存
                        let (data, resp) = try await session.data(for: req)
                        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                            throw StoreError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
                        }
                        return (site.key, .success(data))
                    } catch {
                        return (site.key, .failure(error))
                    }
                }
            }
            for await (key, result) in group {
                switch result {
                case .success(let data):
                    do {
                        let f = try FeedParse.feed(data, siteKey: key)
                        fresh.append(f)
                        try? data.write(to: feedCache(key), options: .atomic)
                    } catch {
                        failures.append("\(key): 解析失败")
                    }
                case .failure(let e):
                    failures.append("\(key): \(short(e))")
                }
            }
        }

        if fresh.isEmpty {
            // 一站都没拉到 —— 保住缓存内容不清空，只挂错误条。
            refreshError = failures.joined(separator: " · ")
            return
        }

        // 部分成功：拿到的站用新数据，没拿到的站**回落到它自己的缓存**，
        // 否则「options 站超时」会表现成「options 的文章全没了」。
        var merged = fresh
        let got = Set(fresh.map(\.site.key))
        for site in Site.all where !got.contains(site.key) {
            if let data = try? Data(contentsOf: feedCache(site.key)),
               let f = try? FeedParse.feed(data, siteKey: site.key) { merged.append(f) }
        }
        apply(merged, stale: !failures.isEmpty)
        refreshError = failures.isEmpty ? nil : failures.joined(separator: " · ")
        lastRefresh = Date()
    }

    // MARK: - 正文

    private func postCache(_ p: FeedPost) -> URL {
        dir.appendingPathComponent("post-\(p.siteKey)-\(p.slug)-\(p.lang).json")
    }

    /// 有缓存直接给（离线可读）；没有才联网，拿到就落盘。
    func body(for p: FeedPost) async -> Result<PostDetail, BodyError> {
        if let data = try? Data(contentsOf: postCache(p)),
           let d = try? FeedParse.post(data) { return .success(d) }

        guard let site = Site.all.first(where: { $0.key == p.siteKey }) else {
            return .failure(BodyError(message: "未知站点 \(p.siteKey)"))
        }
        do {
            var req = URLRequest(url: site.postURL(slug: p.slug, locale: p.lang))
            req.timeoutInterval = 20
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure(BodyError(message: "无响应")) }
            guard http.statusCode == 200 else {
                // 404 在这里是有意义的信号：文章被标了私密，或者这个站还没部署新接口。
                return .failure(BodyError(message: http.statusCode == 404
                    ? "取不到正文（404）—— 文章可能已设为私密，或该站还没部署 /api/post"
                    : "HTTP \(http.statusCode)"))
            }
            let d = try FeedParse.post(data)
            try? data.write(to: postCache(p), options: .atomic)
            return .success(d)
        } catch {
            return .failure(BodyError(message: "离线且没缓存过这篇：\(short(error))"))
        }
    }

    func isCached(_ p: FeedPost) -> Bool {
        FileManager.default.fileExists(atPath: postCache(p).path)
    }

    /// 已缓存正文的篇数 —— 「离线能读几篇」这句话得有个真数字撑着。
    var cachedCount: Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("post-") }.count
    }

    func clearCache() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasPrefix("post-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
        objectWillChange.send()
    }
}

enum StoreError: Error { case http(Int) }

/// 给用户看的失败原因。用它而不是裸 String —— Result 的失败侧必须是 Error。
struct BodyError: Error { let message: String }

private func short(_ e: Error) -> String {
    if case StoreError.http(let c) = e { return "HTTP \(c)" }
    let ns = e as NSError
    switch ns.code {
    case NSURLErrorNotConnectedToInternet: return "没有网络"
    case NSURLErrorTimedOut:               return "超时"
    case NSURLErrorCannotFindHost:         return "域名解析不了"
    default:                               return ns.localizedDescription
    }
}
