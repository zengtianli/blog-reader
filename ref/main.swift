// 回归的 Swift 侧：**跑的是 app 真用的那份 Sources/Feed.swift**（编译时一起传进来），
// 不是照着我以为的实现重写一遍去「实测」——那种测的是替身，会假绿。
import Foundation

struct Row: Encodable {
    let fixture: String
    let siteKey: String
    let siteTitle: String
    let postCount: Int
    let ids: [String]
    let firstTitle: String
    let mergedOrder: [String]
    let zhCount: Int
    let sampleTags: [String]
    let sampleViews: Int
    let sampleExcerptLen: Int
}

let fixtures = ["blog", "options", "ai", "tolerance"]
var out: [Row] = []
var feeds: [Feed] = []

for name in fixtures {
    let url = URL(fileURLWithPath: "ref/fixtures/feed-\(name).json")
    let data = try! Data(contentsOf: url)
    let f = try! FeedParse.feed(data, siteKey: name)
    feeds.append(f)
    let merged = FeedParse.merge([f])
    let p0 = f.posts.first!
    out.append(Row(
        fixture: name,
        siteKey: f.site.key,
        siteTitle: f.site.title,
        postCount: f.posts.count,
        ids: f.posts.map(\.id),
        firstTitle: p0.title,
        mergedOrder: merged.map { "\($0.date)|\($0.title)" },
        zhCount: f.posts.filter { $0.lang == "zh" }.count,
        sampleTags: p0.tags,
        sampleViews: p0.views,
        sampleExcerptLen: p0.excerpt.count
    ))
}

// 三个真站合并后的全局顺序（app 时间线就是这个）
let allMerged = FeedParse.merge(Array(feeds.prefix(3))).map { "\($0.date)|\($0.title)" }

struct Envelope: Encodable { let perFixture: [Row]; let mergedAll: [String] }
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try! enc.encode(Envelope(perFixture: out, mergedAll: allMerged)))
