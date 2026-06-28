# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

DynamicIslandTweak：在越狱 iOS（iOS 15+）的 SpringBoard 上叠加一个 Dynamic Island 风格的悬浮窗，统一展示「正在播放」音乐和通知横幅。仅注入 `com.apple.springboard`（见 `Tweak/DynamicIslandTweak.plist`）。包名 `com.dynamicisland.tweak`，作者 `DaFei`，默认 rootless，CI 兼容 roothide。

## 构建命令

环境：`THEOS=/var/jb/var/mobile/theos`，`ARCHS=arm64 arm64e`，`TARGET=iphone:clang:latest:15.0`，`THEOS_PACKAGE_SCHEME=rootless`。

```sh
# 一次构建全部（tweak dylib + prefs bundle + layout 资源 → deb）
make clean && make package

# roothide 变体（必须先 clean）
make clean && make package THEOS_PACKAGE_SCHEME=roothide
```

顶层 `Makefile` 用 `SUBPROJECTS = Tweak Prefs`，`make package` 一次构建全部：`Tweak/` 产出 dylib + 注入 plist，`Prefs/` 产出 `DynamicIslandPrefs.bundle`，`layout/` 资源一并打包。偏好 bundle 安装到 `/Library/PreferenceBundles/DynamicIslandPrefs.bundle`。

切换 rootless/roothide 必须先 `make clean`。不自动 `make install`、不自动装 deb、不自动 respring。

CI（`.github/workflows/`）走可复用 workflow `langshiyunyi/theos-build@v1`，`scheme: both` 同时产出 rootless + roothide 签名产物；push tag `v*` 触发 Release。

## 架构

运行时数据流：`Tweak.x`（MediaRemote 私有框架 + 通知 hook）→ `DIDisplayManager`（状态机/优先级/timer）→ `DIWindow`（顶层窗口）→ `DIContentView`（岛 UI）。所有跨组件协调走 `DIDisplayManager.sharedInstance` 单例。

### Tweak.x（Logos 入口）
- `%ctor` 只调 `startAfterInjection`，**不在 ctor 里 dispatch 到主线程**；改为监听 `UIApplicationDidFinishLaunchingNotification` 再初始化，30 秒兜底 fallback。
- 音乐数据：`dlopen` `MediaRemote.framework`，运行时 `dlsym` 全部符号（`MRMediaRemoteRegisterForNowPlayingNotifications`、`MRMediaRemoteGetNowPlayingInfo`、`MRMediaRemoteGetNowPlayingClient`、`MRNowPlayingClient*BundleIdentifier`、`kMRMediaRemoteNowPlayingInfo*` 键）。监听 `kMRMediaRemoteNowPlayingInfoDidChangeNotification` 与 `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification`。
- 通知 hook：`%group NotificationHooks` hook `NCNotificationShortLookViewController` 的 `viewWillAppear/viewWillDisappear`。`isVCInBannerContext:` 仅在横幅上下文（非锁屏/通知列表）劫持，避免破坏锁屏通知。`extractNotificationContent` 用 `performSelector` 运行时探测 `content` 的 `title/message/header/icon`，失败安全降级。
- 偏好观察：`CFNotificationCenterAddObserver` 监听 Darwin 通知 `com.dynamicisland.tweak/prefsChanged`，收到后 `reloadPrefs` 并按需重新初始化。
- 延迟初始化：`scheduleTweakInitialization` 推迟 15s，`initializeTweakAfterLaunch` 再延迟 3s 加载 MediaRemote、2s 后首次 `fetchNowPlayingInfo`，避免 SpringBoard 启动早期竞争。
- `syncTick`：播放中每 1s 由 `NSTimer` 触发，刷新进度（elapsed/duration/playbackRate）。

### DIDisplayManager
- 单例 + `DIContentViewDelegate`。持有 `overlayWindow`（`DIWindow`）、`mediaActive`、`showingNotification`、`lastTitle/lastArtist/lastArtwork/lastPlaying/nowPlayingBundleID`。
- **优先级**：通知 > 音乐。`showingNotification` 期间不更新音乐 UI；通知消失后若 `mediaActive && lastPlaying` 调 `switchToMedia` 切回。
- Timer 三件套：`notificationTimer`（自定义时长自动隐藏）、`reappearTimer`（上滑隐藏后延迟再现）、`delayedHideTimer`（连续通知防闪烁，0.3s）。
- 长按展开通知时 `pauseNotificationTimer`/`resumeNotificationTimer` 配对调用。
- 媒体控制：`dlsym` `MRMediaRemoteSendCommand`（`kMRTogglePlayPause=2 / kMRNextTrack=4 / kMRPreviousTrack=5`）与 `MRMediaRemoteSetElapsedTime`（seek）。
- 启动 App：`FBSSystemService openApplication:options:withResult:`（私有路径，首选），失败回退到内置 URL Scheme 表（Music/Spotify/网易云/QQ音乐/酷狗/波点/微信/QQ/支付宝/淘宝/Instagram）。

### DIWindow
`UIWindowLevelStatusBar + 100`。`hitTest:` 在 `state == DIStateHidden` 或 `alpha < 0.1` 时返回 `nil`，保证不挡背景触摸；只在 contentView 命中区返回命中。监听旋转重布局。

### DIContentView（最大文件，~47KB）
状态机：`DIStateHidden/Compact/Expanded/ExpandedFull` × `DIContentTypeMedia/Notification`。
- 音乐紧凑态：封面 + 跑马灯标题 + 4 条波形动画（`CADisplayLink`）。
- 音乐展开态（右滑）：上/下一首、播放暂停。
- 音乐全面板（长按）：大封面 + `UISlider` 进度 + 完整控制。进度用 `playbackRate` + `lastSyncTime` 做计算式真实进度，`CADisplayLink` 驱动。
- 通知态：标题 + 消息跑马灯 + icon；长按展开全文（暂停自动消失 timer）。
- 圆角/边框/尺寸/位置全部从 prefs 读，`reloadPrefs` 刷新。

### 偏好系统（双轨）
1. **PreferenceLoader 内联 spec**（`layout/Library/PreferenceLoader/Preferences/DynamicIslandTweak.plist`）：含 `entry` + 完整 `items` + `PostNotification` 键，无需 bundle 即可在「设置」显示完整面板。配套 `icon.png` 与 `en.lproj/zh-Hans.lproj/DynamicIslandTweak.strings`。
2. **PreferenceBundles bundle**（`Prefs/`，`DIRootListController : PSListController`）：通过 `loadSpecifiersFromPlistName:@"Root"` 加载 `Resources/Root.plist`，额外提供 `saveAllPrefs`（强制写盘 + `CFPreferencesAppSynchronize` + 发 Darwin 通知，解决重启/刷新桌面后参数丢失）和 `resetAllPrefs` 按钮。

偏好 suite：`com.dynamicisland.tweak`。键：`islandEnabled`、`notificationEnabled`、`yOffset`、`compactW/H`、`expandedW`、`fullW/H`、`reappearDelay`、`notifDuration`、`mediaCornerRadius`、`notifCornerRadius`、`borderEnabled/Width/R/G/B`。默认值在 `DIRootListController.m defaultValues`。

### 本地化
`DILocalization.m` 从 `THEOS_PACKAGE_INSTALL_PREFIX /Library/PreferenceLoader/Preferences` 加载 `DynamicIslandTweak.strings`（en + zh-Hans）。tweak 内所有用户可见文案必须走 `DILocalizedString(@"KEY")`，不硬编码。偏好 bundle 走 `[NSBundle bundleForClass:self]` + `Localizable.strings`。新增 UI 文案须同时更新两份 `.strings`。

### 私有头文件
`私有头文件/`（中文目录名）存放 `NCNotificationRequest+Bulletin.h`、`NCNotificationShortLookViewController.h`、`NCNotificationViewController.h`、`LSApplicationWorkspace.h` 仅供参考。**Tweak.x 不 `#include` 它们**，而是在文件内用最小化 `@interface` 声明 + `respondsToSelector`/`performSelector` 运行时探测，失败安全降级。

## 日志约定

- `DILog(fmt, ...)`：`syslog(LOG_NOTICE, "[DynamicIslandTweak] ...")` + `NSLog(@"[Tweak] ...")`，`fmt` 必须是 NSString 字面量（`@"..."`），用 `%s + UTF8String` 拼接避免 C 串/NSString 非法拼接。
- `DIRawLog(fmt, ...)`：C 层 `syslog`，不依赖 Foundation，dyld 阶段可用（ctor 入口）。
- 抓取：`idevicesyslog` / `oslog`（现代 iOS `NSLog` 不落盘、`/var/log/syslog` 不存在）。高频 hook（`syncTick`、`fetchNowPlayingInfo`）内禁重 IO。

## 本地构建 ABI 问题

在本地 iPhone 上用 Procursus theos 构建的 dylib（`Tweak/` 产物）安装后会触发 SpringBoard watchdog / 卡注销，属本地工具链与运行时 iOS arm64e ABI 不兼容问题（已实测复现，iPhone 13 Pro Max / iOS 15.4.1 / rootless）。**只能通过 GitHub Actions 远端构建**（`macos-latest` + roothide/theos + 16.5/15.2/14.5 SDK fallback）产出可用 deb。因此：

- 不要本地 `make install`，也不要安装本地构建的 deb。
- 下载 Release / CI artifact 的 deb 安装验证。
- 本地仅做代码编辑与 `git push`，构建验证看 CI。

## 调试与回滚

- 崩溃日志：`/var/mobile/Library/Logs/CrashReporter/`，排查 selector/类型/UI 线程/野指针/路径/签名/entitlements。
- 工具：`jtool2` / `otool` / `nm` / `ldid`。
- 回滚：`make clean && make package` 重新打包覆盖安装；偏好「恢复默认值」按钮一键重置。
