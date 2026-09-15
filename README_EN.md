[中文](README.md) | **English**

<p align="center"><img src="Resources/icon-1024.png" width="96" alt="My Articles"></p>

# My Articles · blog-reader



**Three blogs in one timeline, readable even without a signal on the subway.**

![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0D84FF?logo=swift&logoColor=white) ![Platform](https://img.shields.io/badge/iOS%2018.0%2B%20·%20macOS%2015.0%2B-000?logo=apple) ![TestFlight](https://img.shields.io/badge/TestFlight-内测中-0D84FF) ![License](https://img.shields.io/badge/License-MIT-green)

All three sites already publish feed.json; the app is simply another consumer. Article bodies are stored in Application Support rather than Caches, which the system may clear when space is tight—removing offline access precisely when it is most needed. Parser regression checks cover 462 values, and negative-case verification caught two real bugs.

<table><tr>
<td align="center" width="25%"><img src="docs/screenshots/01-pub-timeline.png" alt="Three sites in one timeline; a gated site honestly shows “0 articles · Tap here to log in”"><br><sub>Three sites in one timeline; a gated site honestly shows “0 articles · Tap here to log in”</sub></td>
</tr></table>

## What it does

| Feature | Description |
|---|---|
| **Three sites, one feed** | Feeds from three blogs merge into one chronological timeline, with site names as filter chips. Slugs can collide across sites, so IDs include a site prefix. Without it, SwiftUI silently omits entries; the parser regression checks across 462 values caught this bug. |
| **Article bodies stay available offline** | Fetched articles are stored in Application Support rather than Caches, which the system can purge under storage pressure, taking away offline access when it is needed most. Network failures preserve existing content; a timeout affects only its own site. |
| **Gated sites explain why access fails** | One entire site is behind an access gate. If fetching fails, the UI says “Behind an access gate · Tap here to log in,” not a vague “Parsing failed.” Errors must point toward a solution, a rule adopted across the fleet starting with this app. |

## Availability

In TestFlight beta testing; the articles themselves are publicly readable at blog.tianli.cyou.

Reads the three blogs’ public `feed.json` files, including blog.tianli.cyou. Clone the repository and run it. One site is behind an access gate and displays “Tap here to log in.”

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme BlogReader -destination 'generic/platform=iOS Simulator' build
```

- The repository’s `*.sh` files are shims for the author’s local fleet scripts (three-platform builds / device installation / TestFlight). They depend on shared tools under `~/Dev` that are not included here and explicitly exit if those tools are missing.
- `Shared/PlatformCompat.swift` is a byte-for-byte copy of a shared file, providing same-name no-ops on macOS for iOS-only SwiftUI modifiers. Do not edit it here.

See [DEVELOPING.md](DEVELOPING.md) for development details, including regressions, verification channels, and constraints.

## Related

- Product page: <https://apps.tianli.cyou/p/blog-reader-ios.html>
- Fleet overview (where the 10 apps came from): <https://apps.tianli.cyou/ios.html>
- Tutorial: [From Zero to TestFlight: The Complete Path to Building an iPhone App Solo](https://blog-ai.tianli.cyou/nine-ios-apps-in-two-weeks)

## License

MIT © 2026 Tianli Zeng (曾田力)
