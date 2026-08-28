# blog-reader · 我的文章（iOS）

`~/Apps/ios/blog-reader` — 三个博客站合成一条时间线，正文离线可读。
父级形态规则 `~/Apps/ios/CLAUDE.md`，建 app 的通用坑单 `/appios`，全局偏好 `~/.claude/CLAUDE.md`。

## 一句话

`blog` / `blog-options` / `blog-ai` 三站的文章按日期合成一条流，点进去读正文（真渲染 Markdown）。
**取过的正文永久留在本机**，地铁飞机上照样读。

## 数据从哪来（三条，都不是这个 app 新造的）

| 端点 | 谁的 | 说明 |
|---|---|---|
| `https://<站>/feed.json` | blog-site 早就有 | 索引。本来是给「blog 站聚合别站」用的，app 只是又一个消费者 |
| `https://<站>/api/post/<slug>?locale=zh` | **本轮新增** | 正文 Markdown。feed 只带 excerpt，离线读不了 |
| — | — | 三站清单硬编码在 `Sources/Feed.swift` 的 `Site.all`，**只写 URL**，站名从 feed 里读 |

> **正文接口是 `getBlogPostBySlug` 的薄壳。** 私密与归属判定**一律**由那个 SSOT 决定
> （和 `/api/tts/<slug>` 同一做法）。别在接口里加「兜底」判断 —— 那是在造第二个 SSOT，
> 两份判据必然漂移，而漂移的方向是**私密文章从新接口漏出去**。

## `blog-options` 在访问闸后面（2026-08-28）

那个站**整站**挂着 authgate（2026-08-21 用户钦定「整站 authgate，不进任何导航」）。
所以取它的 feed 会拿到 302 → 登录页的 **200 HTML**：

```
GET https://blog-options.tianli.cyou/feed.json
  → 302  location: /_gate/login?next=/feed.json
  → 200  text/html                              ← URLSession 默认跟 302，到手的是这个
```

**表现是那个站静默贡献 0 篇**，错误条上只有一句「options: 解析失败」——
既不像错误、也指不出方向。实测那天它有 **82 篇**文章，一篇都没进来。

用户 2026-08-28 钦定：「我的期权文章也要放到「我的文章」这个 app 里，**这个 app 就我自用**」
→ 授权这个私人客户端**带凭证**读受闸站。

### 三条别改错方向的

1. **不在闸上给 `/feed.json` 开洞。** 那会让期权文章对全网公开，而闸正是用户自己要的。
   客户端拿凭证 ≠ 内容变公开。边界写在 SSOT
   `~/Dev/tools/dev/lib/tools/cc/blog_sites.yaml` 的 `options.access` 注释里。
2. **闸的判据是「最终 URL 落在 `/_gate/` 下」**，不是状态码、也不是 HTML 里有什么字
   （`Gate.blocked(_:)`）。状态码分辨不出来；嗅 HTML 是给页面文案建第二份判据。
3. **存密码不存 cookie。** 会话只有 7 天（服务端 `API_SESSION_DAYS`），存密码才能自动续；
   密码进 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），cookie 交给 URLSession 的
   cookie jar 管，HttpOnly 壳不拆。服务端返回体里那个 `cookie` 字段是给小程序用的，别取。

### 密码怎么进去的（零手工）

```bash
# 只做一次:存进 macOS 钥匙串
security add-generic-password -U -s tlz-gate -a "$(whoami)" -w '<闸密码>'

bash install-to-iphone.sh && bash seed-gate.sh   # 装机 + 喂一次
```

`seed-gate.sh` 从 macOS 钥匙串取密码 → **先在本机验一次**（不验就喂的话，密码错了的
表现是「喂了、没反应」）→ 用 `devicectl ... -- -gatepw <值>` 启动 app 一次。
app 拿到后再验一次、**验过才写 iOS 钥匙串**；错密码静默丢弃（存错密码会让它
每次刷新都去撞限流，而界面上显示的是「已登录」）。

启动参数只在那一次启动里存在（`NSArgumentDomain`），不落 UserDefaults 文件；
主屏点开的启动没有它。

> **为什么密码源是 macOS 钥匙串，不是 `~/.personal_env`**：2026-08-28 实测
> `XCBuildData` 会把构建时的**完整环境连值一起**记进中间产物 —— 当时那里躺着
> 68 个真实凭证的明文。凭证一旦进环境变量，就会跟着构建产物散出去。
> 现在 HQ 的 `install-to-iphone.sh` / `sim-run.sh` 已用 `scrub_env.sh` 摘掉它们，
> 机器层对账 `python3 ~/Dev/tools/dev/lib/tools/macapp/secret_leak_audit.py`。

### 验证

```bash
# 从 VPS 用 TLZ_GATE_SECRET 现签一枚 cookie（不需要知道密码）
CK=$(ssh root@104.218.100.67 'cd /var/www/authgate && set -a && . /etc/tlz/secrets.env && set +a &&   python3 -c "import gate,os; print(gate.issue_cookie(os.environ[\"TLZ_GATE_SECRET\"], days=1)[0])"')
xcrun swiftc -O Sources/Feed.swift Sources/Gate.swift ref/gate/main.swift -o /tmp/gate_probe
PROBE_COOKIE="$CK" /tmp/gate_probe        # 三段：认得出闸 / cookie 过子域 / 解析出 82 篇
```

> ⚠ **`HTTPCookieStorage()` 这个 init 出来的实例是哑对象** —— setCookie 进去
> `cookies` 仍是 0 枚、`cookies(for:)` 永远返回空（2026-08-28 实测）。
> 第一版探针用了它，于是报出「跨子域这条路走不通」这个**假结论**，差点据此把整套设计推翻。
> 必须用 `HTTPCookieStorage.shared`。**测试工具自己出错时，长得跟被测系统出错一模一样。**

## 三条硬规矩

### ① 缓存两段式，且正文放 Application Support 不放 Caches

索引每次开 app 刷（小，要能立刻看到新文章）；正文取到就长期留着（发布后基本不改）。
**Caches 目录 iOS 会在空间紧张时自行清掉** —— 那正好在最需要离线的时候把卖点拿走。

网络失败时**不清空已有内容**：部分站超时 → 那个站回落到自己的缓存，
否则「options 站超时」会表现成「options 的文章全没了」。

### ② `MarkdownView.swift` 是 vendored 的，不是这里写的

上游 `~/Apps/mac/ask-claude/Sources/MarkdownView.swift`。`./check-markdown-drift.sh` 逐字节守着。

**漂了先判方向**：上游改进 → `cp` 过来；本 app 的 iOS 需求 → **改上游让两边都受益**。
在这边分叉之后那道门就永远红，红久了人就不看了。
（为共用同一份文件，上游的 5 处 `Color(nsColor:)` 已收进 `#if os(macOS)` 色板常量；
macOS 侧取值一个没变，ask-claude 观感零变化 —— 改完实测它仍 BUILD SUCCEEDED。）

### ③ 回归打解析层，两侧共读同一批夹具

```bash
node ref/expect.js                                   # → expected.json（按契约算期望）
xcrun swiftc -O Sources/Feed.swift ref/main.swift -o ref/regress
./ref/regress >| ref/actual.json                     # 跑真的 Sources/Feed.swift
node ref/diff.js                                     # → 462 个值 + id 唯一性
```

`ref/fixtures/` = 三站真 feed 快照 + 一份**契约容忍度**夹具（缺可选字段 / 多一个 app 还
不认识的字段 / 同日同 slug 的中英镜像）。契约加字段是向后兼容的，所以除必需字段外
**一律 optional + 默认值** —— 站那边先上线新字段而 app 还没跟上时，不该整份 feed 解析失败。

反向验证过两个真 bug：`id` 去掉 `siteKey`（三站会撞 slug，SwiftUI `ForEach` 静默少渲染）
→ 140 处红；合并排序丢掉「同日按标题」→ 228 处红。

## 构建与装机

```bash
./build.sh                # 模拟器：swiftc 直编 + actool 编图标（fail-closed）
./install-to-iphone.sh    # 真机：挑 Xcode(总部 SSOT) → 找设备 → 取 Team → 编签 → 装
```

`install-to-iphone.sh` 与 `options-calc` 那份**逐字节相同**：项目名 / bundle id / 显示名
全从 `project.yml` 读。所以 `/appios` 教的 `cp -R` 出来的新 app **不用改它** ——
名字写死在脚本里的话，漏改一处的表现是「编的是新 app、装上去的是旧 app」，而它不会报错。

签名 team 2026-08-28 起是**付费**的（`B9LJH93LA4`，证书 1 年期，无 3 个自签上限）。
装机脚本尾部打印的到期日是从包里那张 `embedded.mobileprovision` 实读的，不是写死的文案。
