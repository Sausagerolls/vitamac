# VitaMac

**Your Mac's vital signs, on your iPhone & iPad.**

VitaMac is a native iOS / iPadOS app paired with a lightweight macOS menu-bar
agent. It shows your Mac's live CPU, memory, GPU and network; lists every
running process (per-process CPU/memory, app icons, search, pin-to-top, and
kill); and can restart, sleep, or turn off the display of your Mac — all over
your own local network, end-to-end encrypted, with no cloud and no account.

> **Source-available, not open-source.** The code is published for transparency
> so you can see exactly what runs on your Mac and what the app sends. See
> [`LICENSE`](LICENSE) — viewing is welcome; it is **not** licensed for use,
> building, or redistribution.

Website: <https://giantmushroom.studio/vitamac>

## Architecture

| Module | What it is |
|---|---|
| **MonitorKit** | Shared Codable models, the length-prefixed wire protocol, pairing (HKDF from a code), `SecureChannel` (ChaChaPoly AEAD over TCP), and the `NWConnection`-based client. |
| **AgentCore** | Process + system samplers (`sysctl KERN_PROC_ALL`, `proc_pid_rusage`, `host_statistics64`, IOKit GPU), the killer, the Bonjour + TCP server, the privileged helper, and the `montop` CLI. |
| **MonitorAgent** | The macOS menu-bar agent (no App Sandbox, Hardened Runtime). |
| **Monitor** | The iOS / iPadOS app (`VitaMac`). |

Communication is direct device-to-device over the LAN, sealed with ChaChaPoly
under a key derived from the pairing code. Nothing leaves your network.

## Why two distribution channels

The iOS app ships on the **App Store**. The Mac agent is distributed as a
**notarized Developer ID** download — the App Sandbox the Mac App Store requires
cannot enumerate or terminate other processes, so the agent can't live there.

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
# iOS
xcodebuild -project Monitor.xcodeproj -scheme Monitor -destination 'generic/platform=iOS Simulator' build
# macOS agent
xcodebuild -project Monitor.xcodeproj -scheme MonitorAgent -destination 'platform=macOS' build
# core logic + CLI smoke test
swift test --package-path AgentCore
swift run --package-path AgentCore montop
```

Release/notarization scripts for the Mac agent and the App Store archive for iOS
are in [`scripts/`](scripts/).

## Privacy

No servers, no accounts, no analytics, no tracking. VitaMac never receives any
of your data. See the [privacy policy](https://giantmushroom.studio/vitamac/privacy.html).

---

© 2026 Giant Mushroom Studio
