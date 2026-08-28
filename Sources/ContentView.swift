import SwiftUI

// =============================================================================
// UI：三站合成一条时间线 → 点进去读正文（Markdown 真渲染，不露 ** 和 |---|）。
// 亮色（全局约定：一律浅底深字，不自作主张上深色）。
// =============================================================================

private enum Palette {
    static let bg      = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let card    = Color.white
    static let ink     = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let dim     = Color(red: 0.45, green: 0.47, blue: 0.52)
    static let line    = Color(red: 0.89, green: 0.90, blue: 0.92)
    static let accent  = Color(red: 0.04, green: 0.48, blue: 1.0)
    static let warn    = Color(red: 0.80, green: 0.45, blue: 0.05)

    /// 每站一个色，让时间线上一眼分得出来源。
    static func site(_ key: String) -> Color {
        switch key {
        case "options": return Color(red: 0.15, green: 0.60, blue: 0.35)
        case "ai":      return Color(red: 0.55, green: 0.35, blue: 0.85)
        default:        return accent
        }
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var siteFilter: String? = nil     // nil = 全部
    @State private var query = ""
    @State private var autoOpen: FeedPost?          // --open= 启动参数落点
    @State private var askGate = false
    @State private var gatePw = ""
    @State private var gateErr: String?
    @State private var gateBusy = false

    private var visible: [FeedPost] {
        var xs = store.posts
        // 中英镜像会让同一篇出现两次。默认只看中文，避免时间线上成对重复。
        xs = xs.filter { $0.lang == "zh" }
        if let s = siteFilter { xs = xs.filter { $0.siteKey == s } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            xs = xs.filter {
                $0.title.lowercased().contains(q)
                || $0.excerpt.lowercased().contains(q)
                || $0.tags.contains { t in t.lowercased().contains(q) }
            }
        }
        return xs
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterBar
                    if store.posts.isEmpty && store.loading {
                        Spacer(); ProgressView("正在取三个站的文章…").tint(Palette.accent); Spacer()
                    } else if store.posts.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("我的文章")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜标题 / 摘要 / 标签")
            .navigationDestination(item: $autoOpen) { p in ReaderView(post: p, store: store) }
        }
        .alert("登录访问闸", isPresented: $askGate) {
            SecureField("站群密码", text: $gatePw)
            Button("登录") { Task { await signInGate() } }
            Button("取消", role: .cancel) { gatePw = "" }
        } message: {
            Text(gateErr ?? ("投资日复盘整站挂着访问闸。密码只存本机钥匙串，验过才存；"
                             + "会话到期会自动续，不用再输。"))
        }
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .task {
            await store.refresh()
            // 截图/验收用：`--open=<siteKey>/<slug>` 直接进阅读页。
            // 靠手点模拟器截不出可复现的图，改一版就得重点一遍。
            if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open=") }) {
                let parts = arg.dropFirst("--open=".count).split(separator: "/", maxSplits: 1)
                if parts.count == 2,
                   let hit = store.posts.first(where: {
                       $0.siteKey == String(parts[0]) && $0.slug == String(parts[1]) && $0.lang == "zh"
                   }) { autoOpen = hit }
            }
        }

    }

    /// 撞闸的站名 —— 用 feed 里的站名，拿不到（从没成功取过）才回落到 key。
    private var gatedNames: String {
        store.gated.map { store.siteTitles[$0] ?? $0 }.joined(separator: " / ")
    }

    private func signInGate() async {
        let pw = gatePw; gatePw = ""
        guard !pw.isEmpty else { return }
        gateBusy = true
        gateErr = await store.signInGate(pw)
        gateBusy = false
        // 登进去了但站还在 gated 里 = cookie 没生效,这种要说出来,别静默
        if gateErr == nil && !store.gated.isEmpty {
            gateErr = "登录成功了，但这些站仍被拦：\(gatedNames)"
        }
        if gateErr != nil { askGate = true }
    }

    // MARK: 站点筛选

    private var filterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "全部 \(store.posts.filter { $0.lang == "zh" }.count)",
                         color: Palette.ink, active: siteFilter == nil) { siteFilter = nil }
                    ForEach(Site.all) { s in
                        let n = store.posts.filter { $0.siteKey == s.key && $0.lang == "zh" }.count
                        chip(title: "\(store.siteTitles[s.key] ?? s.key) \(n)",
                             color: Palette.site(s.key), active: siteFilter == s.key) {
                            siteFilter = siteFilter == s.key ? nil : s.key
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            // 撞闸单独一条,且**可点** —— 「需要登录」是有解的,横幅本身就得是那个入口。
            // 只显示一句「取不到」而不给按钮,等于告诉人「坏了,但你也没辙」。
            if !store.gated.isEmpty {
                Button {
                    gateErr = nil; gatePw = ""; askGate = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 11))
                        Text("\(gatedNames) 在访问闸后面 · 点这里登录")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .foregroundStyle(Palette.site("options"))
                    .padding(.horizontal, 14).padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let err = store.refreshError {
                banner(icon: "wifi.slash", text: "刷新没成功，下面是本机缓存 · \(err)", color: Palette.warn)
            } else if store.isStale && !store.posts.isEmpty {
                banner(icon: "clock.arrow.circlepath", text: "本机缓存，正在刷新…", color: Palette.dim)
            }
            Divider().background(Palette.line)
        }
        .background(Palette.card)
    }

    private func chip(title: String, color: Color, active: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : color)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? color : color.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12)); Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    // MARK: 时间线

    private var list: some View {
        List {
            ForEach(visible) { p in
                NavigationLink { ReaderView(post: p, store: store) } label: { row(p) }
                    .listRowBackground(Palette.card)
            }
            Section {
                HStack {
                    Text("已离线缓存 \(store.cachedCount) 篇正文").font(.system(size: 12)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("清缓存") { store.clearCache() }.font(.system(size: 12))
                }
            }
            .listRowBackground(Palette.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        // 搜索框是**浮在内容之上**的（iOS 26 起），不留这块白就会盖住最后一行 ——
        // 实测截图里「涨了 0.73%」那条被压在搜索框下面看不全。
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 52) }
        .refreshable { await store.refresh() }
    }

    private func row(_ p: FeedPost) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(store.siteTitles[p.siteKey] ?? p.siteKey)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.site(p.siteKey))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.site(p.siteKey).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                Text(p.date).font(.system(size: 11)).foregroundStyle(Palette.dim)
                if store.isCached(p) {
                    // 有这个标才敢说「这篇离线能读」——不靠猜，查的是文件在不在。
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(Palette.dim.opacity(0.7))
                }
                Spacer()
                if p.views > 0 {
                    Text("\(p.views) 人看过").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
            }
            Text(p.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !p.excerpt.isEmpty {
                Text(p.excerpt).font(.system(size: 13)).foregroundStyle(Palette.dim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(Palette.dim)
            Text("一篇都没取到").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
            if let e = store.refreshError {
                Text(e).font(.system(size: 12)).foregroundStyle(Palette.warn)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Button("重试") { Task { await store.refresh() } }.font(.system(size: 14))
            Spacer()
        }
    }
}

// MARK: - 阅读页

struct ReaderView: View {
    let post: FeedPost
    @ObservedObject var store: Store
    @State private var detail: PostDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(post.title).font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(store.siteTitles[post.siteKey] ?? post.siteKey)
                        .foregroundStyle(Palette.site(post.siteKey))
                    Text(post.date)
                    if !post.tags.isEmpty { Text(post.tags.prefix(3).joined(separator: " · ")) }
                }
                .font(.system(size: 12)).foregroundStyle(Palette.dim)
                Divider().background(Palette.line)

                if let d = detail {
                    // 真渲染 markdown —— 这是从 ask-claude vendored 过来的渲染器，
                    // check-markdown-drift.sh 守着它和上游逐字节一致。
                    MarkdownText(text: d.markdown)
                        .foregroundStyle(Palette.ink)
                } else if let e = error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("读不到正文", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.warn)
                        Text(e).font(.system(size: 13)).foregroundStyle(Palette.dim)
                        Text(post.excerpt).font(.system(size: 14)).foregroundStyle(Palette.ink)
                            .padding(.top, 4)
                    }
                } else {
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(18)
        }
        .background(Palette.bg)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch await store.body(for: post) {
            case .success(let d): detail = d
            case .failure(let e): error = e.message
            }
        }
    }
}
