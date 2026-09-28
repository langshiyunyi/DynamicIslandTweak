# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DynamicIslandTweak is an iOS jailbreak tweak that overlays a Dynamic Island-style floating window on SpringBoard to display "Now Playing" music controls and notification banners. It only injects into `com.apple.springboard`.

**Compatibility:**
- iOS 15.0+ only (depends on iOS 15+ private APIs that don't exist on iOS 14 and below)
- rootless and roothide jailbreak types supported
- arm64 and arm64e architectures

## Build Commands

**⚠️ Local builds are NOT supported.** Local iPhone builds with Procursus theos trigger SpringBoard watchdog crashes due to arm64e ABI incompatibilities. **Must use GitHub Actions for remote builds.**

```bash
# Build via GitHub Actions (required)
git push  # triggers .github/workflows/build.yml

# For local reference only (DO NOT install locally):
make clean && make package                                    # rootless (default)
make clean && make package THEOS_PACKAGE_SCHEME=roothide     # roothide
```

The top-level Makefile uses `SUBPROJECTS = Tweak Prefs` to build both the tweak dylib and preferences bundle in one pass.

## Architecture

### Data Flow
```
Tweak.x (Logos entry, MediaRemote + notification hooks)
  ↓
DIDisplayManager (singleton: state machine / priority / timers)
  ↓
DIWindow (top-level window at UIWindowLevelStatusBar + 100, hit-test passthrough)
  ↓
DIContentView (state machine UI: Hidden/Compact/Expanded/ExpandedFull × Media/Notification)
```

### State Machine & Priority
- **Priority:** Notification > Music. During `showingNotification`, music UI updates are suppressed.
- **Three timers:** `notificationTimer` (auto-dismiss), `reappearTimer` (re-show after swipe-up), `delayedHideTimer` (batch consecutive notifications)
- **Media control:** Uses `MRMediaRemoteSendCommand` (play/pause/next/prev) and `MRMediaRemoteSetElapsedTime` (seek)

### Private API Loading
- `Tweak.x` uses `dlopen` + `dlsym` to load `MediaRemote.framework` private symbols at runtime
- Notification content fields (`title`, `message`, `icon`) are probed with `respondsToSelector` / `performSelector` and gracefully degrade on failure
- The `私有头文件/` directory contains reference headers (`NCNotificationShortLookViewController.h`, `NCNotificationRequest+Bulletin.h`, `NCNotificationViewController.h`, `LSApplicationWorkspace.h`) for documentation only — **Tweak.x does NOT `#include` them**

## Project Structure

```
Tweak/
├── Tweak.x                     # Logos entry: MediaRemote dlopen, notification hooks, startup timing
├── DIDisplayManager.m/.h       # Singleton: state machine, priority logic, three timers
├── DIContentView.m/.h          # UI state machine, animations, gestures (swipe, long-press)
├── DIWindow.m/.h               # Top-level window with touch passthrough (hitTest returns nil when hidden)
├── DILocalization.m/.h         # Localization helper
├── DynamicIslandTweak.plist    # Injection filter (com.apple.springboard only)
└── Makefile                    # tweak.mk

Prefs/
├── DIRootListController.m/.h   # PSListController with saveAllPrefs / resetAllPrefs buttons
├── Resources/
│   ├── Root.plist              # Preference pane spec
│   ├── Info.plist
│   ├── en.lproj/               # English
│   └── zh-Hans.lproj/          # Simplified Chinese
└── Makefile                    # bundle.mk, uses Preferences private framework

layout/Library/PreferenceLoader/Preferences/
├── DynamicIslandTweak.plist    # Inline preference spec (entry + items + PostNotification)
├── icon.png / @2x / @3x        # Settings entry icon (29x29 / 58x58 / 87x87 PNG)
├── en.lproj/
└── zh-Hans.lproj/
```

## Key Implementation Details

### Artwork Handling
- **Priority 1:** `kMRMediaRemoteNowPlayingInfoArtworkData` — downsampled via ImageIO to 600px max (removes 5MB hard-drop, auto-scales large images)
- **Priority 2:** `kMRMediaRemoteNowPlayingInfoArtworkURL` — async download with generation checking to prevent stale artwork from overwriting new tracks
- **Priority 3:** App icon fallback via `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]` when artwork fails
- **Retry logic:** Up to 2 retries with 1.5s delay when no real artwork is available; abandoned if track changes (`_artworkGeneration` mismatch)

### Progress (Fake Progress Mode - Since 2026-09-28)
- **System elapsed 仅在新曲目时作为起点**，之后完全本地推进（每秒 +1）
- 拖动进度条后，从拖动位置继续本地计时（`lastSyncTime` 重置）
- 不再每 5 秒同步系统真实进度，避免进度条"跳跃"
- `progressStep` 方法固定 `trackElapsed += delta`（忽略 playbackRate）
- `updateElapsed` 在新曲目时（`fabs(duration - trackDuration) > 1.0`）才更新 `trackElapsed`

### Notification Display
- **优化后的布局（Since 2026-09-28）**：紧凑模式图标 28x28，左边距 10pt，图标与文字间距 8pt
- 标题和消息垂直居中对齐，总文本高度 `titleH + lineGap + msgH`，从 `(height - totalTextH) / 2` 开始
- 长消息自动启用跑马灯滚动（marquee）
- 长按展开为系统横幅大小，支持多行消息显示

### Notification Hooks
- Hook `NCNotificationShortLookViewController` `viewWillAppear` / `viewWillDisappear`
- Only process banners (verified via `isVCInBannerContext` — checks view/parent hierarchy for "Banner" class names)
- Hides the original system banner by setting `self.view.hidden = YES; self.view.alpha = 0` (does NOT touch system banner containers to avoid state machine crashes)
- Delayed hide with 0.3s timer to batch consecutive notifications

### Logging
- `DILog(fmt, ...)`: `syslog` + `NSLog`, always on
- `DIVLog(fmt, ...)`: Verbose logs (default OFF in Release, controlled by `verboseLog` pref), wraps high-frequency calls (`syncTick`, `fetchNowPlayingInfo`)
- `DIRawLog(fmt, ...)`: C-level `syslog`, works in dyld phase
- Capture logs via `idevicesyslog` or `oslog` (modern iOS doesn't write NSLog to disk; `/var/log/syslog` doesn't exist)

### Preferences
- Suite name: `com.dynamicisland.tweak`
- Darwin notification: `com.dynamicisland.tweak/prefsChanged`
- On notification, `DIDisplayManager` calls `reloadPrefs` and re-initializes if needed
- The Prefs bundle provides "Save All" and "Restore Defaults" buttons to solve parameter loss after respring or desktop refresh

## Localization

All user-facing strings use `DILocalizedString(@"KEY")`. When adding UI text, update all four files:
- `layout/Library/PreferenceLoader/Preferences/en.lproj/DynamicIslandTweak.strings`
- `layout/Library/PreferenceLoader/Preferences/zh-Hans.lproj/DynamicIslandTweak.strings`
- `Prefs/Resources/en.lproj/Localizable.strings`
- `Prefs/Resources/zh-Hans.lproj/Localizable.strings`

## GitHub Actions

- `.github/workflows/build.yml`: Builds both rootless and roothide variants on `macos-latest` with roothide/theos + iOS SDK fallback (14.5 / 15.2 / 16.5)
- `.github/workflows/release.yml`: Auto-creates GitHub Release when a `v*` tag is pushed
- **Critical fix:** `DynamicIslandPrefs_LDFLAGS="-F$(THEOS_SDK_PATH)/System/Library/PrivateFrameworks"` is required in CI to link the Preferences private framework

## Common Patterns

### Adding a New Preference
1. Add the key/default to `DIDisplayManager -reloadPrefs`
2. Add the UI control to `Prefs/Resources/Root.plist`
3. Update localization strings in all four `.strings` files
4. Test Darwin notification delivery: change the pref in Settings and verify `DILog` shows "prefsChanged" fired

### Modifying the State Machine
- **Media → Notification transition:** Check `showingNotification` flag in `DIDisplayManager` before updating media UI
- **Notification → Media transition:** Call `hideNotification`, which checks `mediaActive` and auto-transitions back to media if playing
- All state changes must run on the main queue

### Debugging Startup
- Tweak waits for `UIApplicationDidFinishLaunchingNotification` before initializing (with 30s fallback)
- MediaRemote loading happens 3s after launch notification
- Notification hooks are initialized 15s after launch if `notificationEnabled` is true
- Check logs for "startAfterInjection begin", "UIApplicationDidFinishLaunching received", "mediaRemoteLoaded=1"
