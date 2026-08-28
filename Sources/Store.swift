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
    /// 被访问闸挡住、且这一轮没能自动登进去的站（站 key）。
    /// **必须单独一个状态、不能混进 refreshError** —— 「需要登录」是有解的
    /// （输个密码就行），「超时」是没解的，混成一句话就没人知道该干什么。
    @Published private(set) var gated: [String] = []

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
        var blocked: [Site] = []

        var results = await fetchAll(Site.all)
        blocked = Site.all.filter { results[$0.key]?.isGate == true }

        // 撞闸了、而且手里有密码 → **自动换一次会话再重试**。
        // 会话只有 7 天（服务端 API_SESSION_DAYS），不自动续的话就变成
        // 「每周有一天期权文章会凭空消失」，而且没人知道为什么。
        if !blocked.isEmpty, let pw = Gate.password {
            do {
                try await Gate.login(password: pw, session: session)
                let retried = await fetchAll(blocked)
                for (k, v) in retried { results[k] = v }
                blocked = blocked.filter { results[$0.key]?.isGate == true }
            } catch {
                // 密码存着却登不进（改过密码 / 撞限流）—— 说出服务端原话，
                // 别吞掉后把它显示成「需要登录」，那会让人一直重输同一个错密码。
                failures.append("访问闸: \((error as? Gate.Failure)?.message ?? "登录失败")")
                Gate.forgetPassword()
            }
        }

        for site in Site.all {
            switch results[site.key] {
            case .ok(let data):
                do {
                    let f = try FeedParse.feed(data, siteKey: site.key)
                    fresh.append(f)
                    try? data.write(to: feedCache(site.key), options: .atomic)
                } catch {
                    failures.append("\(site.key): 解析失败")
                }
            case .gate:
                break                       // 不进 failures，走 gated 那条独立的路
            case .fail(let msg):
                failures.append("\(site.key): \(msg)")
            case nil:
                failures.append("\(site.key): 没有结果")
            }
        }
        gated = blocked.map(\.key)

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

    /// 一轮并发取 feed。串行的话最慢那个站决定整体等待时间，而它们互不依赖。
    private func fetchAll(_ sites: [Site]) async -> [String: FetchOutcome] {
        var out: [String: FetchOutcome] = [:]
        await withTaskGroup(of: (String, FetchOutcome).self) { group in
            for site in sites {
                group.addTask { [session] in
                    do {
                        var req = URLRequest(url: site.feedURL)
                        req.timeoutInterval = 15
                        req.cachePolicy = .reloadIgnoringLocalCacheData   // 我们自己管缓存
                        let (data, resp) = try await session.data(for: req)
                        // 闸的判据必须在状态码之前：URLSession 默认跟 302，
                        // 到手的是登录页的 **200**，只看状态码分辨不出来。
                        if Gate.blocked(resp) { return (site.key, .gate) }
                        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                            return (site.key, .fail("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"))
                        }
                        return (site.key, .ok(data))
                    } catch {
                        return (site.key, .fail(short(error)))
                    }
                }
            }
            for await (k, v) in group { out[k] = v }
        }
        return out
    }

    // MARK: - 访问闸

    var gateHasCredential: Bool { Gate.hasPassword }

    /// 用户输了闸密码 → 登进去、记住、立刻重刷。成功返回 nil，失败返回给人看的原因。
    func signInGate(_ password: String) async -> String? {
        do {
            try await Gate.login(password: password, session: session)
            Gate.savePassword(password)          // 只在**验过**之后才存，不存没用的错密码
            await refresh()
            return nil
        } catch {
            return (error as? Gate.Failure)?.message ?? "登录失败"
        }
    }

    func signOutGate() {
        Gate.forgetPassword()
        objectWillChange.send()
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
            var (data, resp) = try await session.data(for: req)
            // 正文接口同样在闸后面。撞上了就换一次会话重来一遍 ——
            // 少了这段的表现是「列表里看得见标题，点进去永远打不开」。
            if Gate.blocked(resp), let pw = Gate.password {
                try? await Gate.login(password: pw, session: session)
                (data, resp) = try await session.data(for: req)
            }
            if Gate.blocked(resp) {
                return .failure(BodyError(message: "这个站要先登录访问闸（去列表顶部那条横幅）"))
            }
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

/// 取一个站 feed 的三种结局。**「撞闸」必须是独立的一种** ——
/// 把它折进 .fail 的话，一句「options: 解析失败」既不像错误也指不出方向
/// （2026-08-28 实测就是这么丢了 82 篇文章的）。
enum FetchOutcome {
    case ok(Data)
    case gate
    case fail(String)

    var isGate: Bool { if case .gate = self { return true }; return false }
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
