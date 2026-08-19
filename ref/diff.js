// 逐字段比。字符串**逐字**，数组逐元素 —— 不做「大致相同」这种判定。
const fs = require("fs")
const exp = JSON.parse(fs.readFileSync("ref/expected.json", "utf8"))
const act = JSON.parse(fs.readFileSync("ref/actual.json", "utf8"))

let checks = 0
const bad = []
function walk(path, a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return bad.push(`${path}: 一边不是数组`)
    if (a.length !== b.length) return bad.push(`${path}: 长度 ${a.length} vs ${b.length}`)
    a.forEach((_, i) => walk(`${path}[${i}]`, a[i], b[i]))
    return
  }
  if (a && typeof a === "object") {
    const ks = new Set([...Object.keys(a), ...Object.keys(b || {})])
    for (const k of ks) walk(`${path}.${k}`, a[k], (b || {})[k])
    return
  }
  checks += 1
  if (a !== b) bad.push(`${path}: 期望 ${JSON.stringify(a)} 实得 ${JSON.stringify(b)}`)
}
walk("root", exp, act)

// 额外一条结构性断言：id 必须全局唯一（撞了的话 SwiftUI ForEach 会静默少渲染）
const allIds = act.perFixture.flatMap((f) => f.ids)
const dup = allIds.filter((x, i) => allIds.indexOf(x) !== i)
if (dup.length) bad.push(`id 撞车 ${dup.length} 处: ${[...new Set(dup)].slice(0, 5).join(", ")}`)
checks += 1

if (bad.length) {
  console.error(`❌ ${bad.length} 处不一致（共比 ${checks} 个值）`)
  bad.slice(0, 25).forEach((b) => console.error("   " + b))
  process.exit(1)
}
console.log(`✅ ${act.perFixture.length} 份夹具 / ${checks} 个值 + id 唯一性 → 全部一致`)
