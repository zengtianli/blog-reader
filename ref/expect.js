// 回归的「另一侧」：用 node 直接读**同一批夹具**，按契约算出期望值。
// 两侧共读同一份输入 —— 各写一份参数的话，「全部一致」可能只是两边喂的东西本来就不同。
const fs = require("fs")
const FIX = ["blog", "options", "ai", "tolerance"]

const load = (n) => JSON.parse(fs.readFileSync(`ref/fixtures/feed-${n}.json`, "utf8"))
const key = (p) => `${p.date}|${p.title}`
const cmp = (a, b) => (a.date === b.date ? (a.title < b.title ? -1 : a.title > b.title ? 1 : 0)
                                         : (a.date > b.date ? -1 : 1))

const perFixture = FIX.map((name) => {
  const f = load(name)
  const p0 = f.posts[0]
  return {
    fixture: name,
    siteKey: f.site.key,
    siteTitle: f.site.title,
    postCount: f.posts.length,
    // id 必须带 siteKey —— 三站合并后不同站会撞 slug
    ids: f.posts.map((p) => `${name}/${p.slug}/${p.lang ?? "zh"}`),
    firstTitle: p0.title,
    mergedOrder: [...f.posts].sort(cmp).map(key),
    zhCount: f.posts.filter((p) => (p.lang ?? "zh") === "zh").length,
    sampleTags: p0.tags ?? [],
    sampleViews: p0.views ?? 0,
    sampleExcerptLen: [...(p0.excerpt ?? "")].length,   // Swift 的 String.count 按字素簇
  }
})

const three = FIX.slice(0, 3).flatMap((n) => load(n).posts)
const out = { perFixture, mergedAll: [...three].sort(cmp).map(key) }
fs.writeFileSync("ref/expected.json", JSON.stringify(out, null, 2))
console.log(`expected.json: ${perFixture.length} 份夹具 / 合并后 ${out.mergedAll.length} 条`)
