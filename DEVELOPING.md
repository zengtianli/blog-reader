# blog-reader · 我的文章（iOS）

`blog` / `blog-options` / `blog-ai` 三个博客站合成一条时间线，正文离线可读。

```bash
./build.sh                # 模拟器
./install-to-iphone.sh    # 真机（免费 Personal Team，证书 7 天到期，重跑即续）
```

回归：

```bash
node ref/expect.js && xcrun swiftc -O Sources/Feed.swift ref/main.swift -o ref/regress \
  && ./ref/regress >| ref/actual.json && node ref/diff.js      # 解析层 462 个值
xcrun swiftc -O -parse-as-library Sources/Feed.swift Sources/Store.swift ref/offline.swift \
  -o ref/offline && ./ref/offline                               # 离线可读 4 条
./check-markdown-drift.sh                                       # 渲染器与上游一致
```

约束与踩坑见 `CLAUDE.md`；形态族规则见 `~/Apps/ios/CLAUDE.md`。
