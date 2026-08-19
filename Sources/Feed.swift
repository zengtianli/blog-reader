import Foundation

// =============================================================================
// 数据层：站点 / feed 索引 / 单篇正文 —— 纯值逻辑，零 UI、零 SwiftUI 依赖，
// 可用 swiftc 单独编译对拍（ref/main.swift 就是这么跑回归的）。
//
// 接口契约的**唯一权威**是站那边：
//   ~/Dev/stations/blog-site/app/feed.json/route.ts       索引
//   ~/Dev/stations/blog-site/app/api/post/[slug]/route.ts 正文
// 这里的 Codable 只是那份契约的消费端。契约加字段是向后兼容的（feed 加 views
// 就是这么加的），所以**除必需字段外一律 optional + 默认值** —— 站那边先上线一个
// 新字段、app 还没跟上时，不该整份 feed 解析失败。
// =============================================================================

/// 一个博客子站。**只硬编码 URL** —— 标题从 feed 里读，别在两处各写一份。
struct Site: Identifiable, Hashable {
    let key: String
    let url: String
    var id: String { key }

    /// 三站清单。加站 = 在这里加一行 + 那个站得能返回 /feed.json。
    static let all: [Site] = [
        Site(key: "blog",    url: "https://blog.tianli.cyou"),
        Site(key: "options", url: "https://blog-options.tianli.cyou"),
        Site(key: "ai",      url: "https://blog-ai.tianli.cyou"),
    ]

    var feedURL: URL { URL(string: "\(url)/feed.json")! }
    func postURL(slug: String, locale: String) -> URL {
        var c = URLComponents(string: "\(url)/api/post/\(slug)")!
        c.queryItems = [URLQueryItem(name: "locale", value: locale)]
        return c.url!
    }
}

// MARK: - feed.json

struct FeedSite: Codable, Hashable {
    let key: String
    let title: String
    let url: String
}

struct FeedPost: Codable, Hashable, Identifiable {
    let slug: String
    let lang: String
    let title: String
    let date: String          // YYYY-MM-DD
    let excerpt: String
    let tags: [String]
    let category: String?
    let series: String?
    let image: String?
    let url: String
    let views: Int

    /// 同一个 slug 会在中英两条里各出现一次，所以 id 必须带 lang，
    /// 还得带站 key —— 三站合并后不同站可能撞 slug（`about` 这种）。
    /// 少了任何一段，SwiftUI 的 ForEach 会静默只渲染其中一条。
    var siteKey: String = ""
    var id: String { "\(siteKey)/\(slug)/\(lang)" }

    private enum CodingKeys: String, CodingKey {
        case slug, lang, title, date, excerpt, tags, category, series, image, url, views
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug     = try c.decode(String.self, forKey: .slug)
        title    = try c.decode(String.self, forKey: .title)
        date     = try c.decode(String.self, forKey: .date)
        url      = try c.decode(String.self, forKey: .url)
        lang     = try c.decodeIfPresent(String.self, forKey: .lang) ?? "zh"
        excerpt  = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        tags     = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category)
        series   = try c.decodeIfPresent(String.self, forKey: .series)
        image    = try c.decodeIfPresent(String.self, forKey: .image)
        views    = try c.decodeIfPresent(Int.self, forKey: .views) ?? 0
    }

    /// 测试用直造（回归里要能不经 JSON 构一条）。
    init(slug: String, lang: String, title: String, date: String, excerpt: String = "",
         tags: [String] = [], category: String? = nil, series: String? = nil,
         image: String? = nil, url: String = "", views: Int = 0, siteKey: String = "") {
        self.slug = slug; self.lang = lang; self.title = title; self.date = date
        self.excerpt = excerpt; self.tags = tags; self.category = category
        self.series = series; self.image = image; self.url = url; self.views = views
        self.siteKey = siteKey
    }
}

struct Feed: Codable {
    let site: FeedSite
    let generated_at: String
    let posts: [FeedPost]
}

// MARK: - /api/post/<slug>

struct PostDetail: Codable {
    let slug: String
    let locale: String
    let title: String
    let date: String
    let markdown: String
    let url: String

    private enum CodingKeys: String, CodingKey { case slug, locale, title, date, markdown, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug     = try c.decode(String.self, forKey: .slug)
        title    = try c.decode(String.self, forKey: .title)
        markdown = try c.decode(String.self, forKey: .markdown)
        locale   = try c.decodeIfPresent(String.self, forKey: .locale) ?? "zh"
        date     = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        url      = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    init(slug: String, locale: String, title: String, date: String, markdown: String, url: String) {
        self.slug = slug; self.locale = locale; self.title = title
        self.date = date; self.markdown = markdown; self.url = url
    }
}

// MARK: - 解析（纯函数，回归直接打这一层）

enum FeedParse {
    /// 解析 feed.json，并把站 key 盖进每条 post（id 需要它去重）。
    static func feed(_ data: Data, siteKey: String) throws -> Feed {
        let f = try JSONDecoder().decode(Feed.self, from: data)
        let stamped = f.posts.map { p -> FeedPost in
            var q = p; q.siteKey = siteKey.isEmpty ? f.site.key : siteKey; return q
        }
        return Feed(site: f.site, generated_at: f.generated_at, posts: stamped)
    }

    static func post(_ data: Data) throws -> PostDetail {
        try JSONDecoder().decode(PostDetail.self, from: data)
    }

    /// 三站合并 → 按日期倒序。同日按标题稳定排序，**不留「同日顺序每次开 app 都变」**
    /// 这种会让人以为有新文章的抖动。
    static func merge(_ feeds: [Feed]) -> [FeedPost] {
        feeds.flatMap(\.posts).sorted {
            $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date
        }
    }
}
