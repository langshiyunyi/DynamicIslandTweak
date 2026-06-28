# DynamicIslandTweak

在越狱 iOS 上为 SpringBoard 叠加一个 Dynamic Island 风格的悬浮窗，统一展示「正在播放」音乐和通知横幅。仅注入 `com.apple.springboard`，包名 `com.dynamicisland.tweak`，作者 DaFei。

## 功能特性

- **音乐控制**：封面 / 标题 / 艺术家 / 进度 / 上一首 / 下一首 / 播放暂停 / 进度拖动（seek）
- **通知横幅**：标题 / 消息 / 应用图标 / 长按展开全文（暂停自动消失计时）
- **三态 UI**：紧凑态（Compact）/ 展开态（Expanded）/ 全面板（ExpandedFull），右滑展开、长按全面板
- **优先级状态机**：通知 > 音乐；通知消失后自动切回正在播放的音乐
- **触摸穿透**：`DIWindow` 在隐藏态或非命中区返回 `nil`，不挡背景触摸
- **完整偏好面板**：尺寸 / 位置 / 圆角 / 边框 / 时长 / 开关全部可调，Darwin 通知即时生效，无需 respring
- **双语**：中文（zh-Hans）+ 英文（en）
- **双 scheme**：rootless + roothide CI 同时产出

## 兼容性

### iOS 版本

| iOS | 状态 | 说明 |
|---|:---:|---|
| 15.0 – 15.x | ✅ 支持 | 已验证（iPhone 13 Pro Max / iOS 15.4.1 / rootless） |
| 16.0 – 16.x | ✅ 支持 | 已验证 |
| 17.0+ | ⚠️ 未测 | 理论兼容，未实测 |
| 14.x 及以下 | ❌ 不支持 | 见下方说明 |

**iOS 14 及以下不支持的原因**：

本插件依赖 iOS 15+ 才存在的私有框架与类结构，14 及以下**没有对应的框架接口可 hook**，无法向下兼容：

- **`MediaRemote.framework` 私有 API**：`MRMediaRemoteGetNowPlayingInfo`、`MRMediaRemoteGetNowPlayingClient`、`MRMediaRemoteSendCommand`、`MRMediaRemoteSetElapsedTime`、`kMRMediaRemoteNowPlayingInfo*` 键等符号在 iOS 15+ 才稳定可用；iOS 14 的媒体远程接口形态不同，运行时 `dlsym` 取不到当前实现所需的全部符号。
- **通知中心私有类**：hook 点 `NCNotificationShortLookViewController` 的 `viewWillAppear/viewWillDisappear` 与 `isVCInBannerContext:` 在 iOS 15+ 才存在；iOS 14 走 `UNNotification` + 旧 Bulletin 路径，类结构完全不同。
- **SpringBoard 启动时序**：`UIApplicationDidFinishLaunchingNotification` + `FBSSystemService openApplication:options:withResult:` 私有 API 在 iOS 15+ 才有当前实现所依赖的接口形态。
- **没有可参照的 iOS 14 私有头文件**：`私有头文件/` 中的 `NCNotificationShortLookViewController.h`、`NCNotificationRequest+Bulletin.h`、`NCNotificationViewController.h`、`LSApplicationWorkspace.h` 均基于 iOS 15+ 逆向，14 及以下无对应符号。

### 越狱类型

| 类型 | 状态 | 说明 |
|---|:---:|---|
| rootless | ✅ 支持 | 默认构建（Dopamine 2.x / palera1n rootless） |
| roothide | ✅ 支持 | CI 产出 roothide 变体，`THEOS_PACKAGE_SCHEME=roothide` |
| rootful | ❌ 不支持 | `layout/` 路径为 jbroot 布局，未适配传统 `/` 越狱 |

### 设备架构

- **arm64**（A7 – A11）：iPhone 5s – iPhone X
- **arm64e**（A12+）：iPhone XS 及更新

`Makefile` 中 `ARCHS = arm64 arm64e`，两种架构同时编译。

## 安装

### 下载 deb

从 [Releases](../../releases) 下载对应你越狱类型的 deb：

- `com.dynamicisland.tweak_*_iphoneos-arm64.deb` —— rootless
- `com.dynamicisland.tweak_*_iphoneos-arm64e.deb` —— roothide

### 安装

```sh
dpkg -i com.dynamicisland.tweak_*.deb
killall SpringBoard
```

### 卸载

```sh
dpkg -r com.dynamicisland.tweak
killall SpringBoard
```

## 配置

「设置」App 中找到 **Dynamic Island** 入口（图标为本插件自带），可调整：

- 总开关 / 通知开关
- Y 位移、紧凑态宽高、展开态宽、全面板宽高
- 圆角（音乐 / 通知分别可调）
- 边框开关 / 宽度 / RGB
- 通知持续时长、上滑隐藏后再现延迟

偏好通过 Darwin 通知 `com.dynamicisland.tweak/prefsChanged` 即时下发，tweak 收到后 `reloadPrefs` 并按需重新初始化。偏好 bundle（`Prefs/`）额外提供「保存全部」与「恢复默认值」按钮，解决重启或刷新桌面后参数丢失的问题。

## 构建

环境：Theos（rootless 或 roothide fork），iOS SDK 15.0+。

> **⚠️ 本地构建不可用**
> 在本地 iPhone 上用 Procursus theos 构建的 dylib 安装后会触发 SpringBoard watchdog / 卡注销，属本地工具链与运行时 arm64e ABI 不兼容问题。**必须使用 GitHub Actions 远端构建**（macos-latest + roothide/theos + 16.5/15.2/14.5 SDK fallback）。下载 Release 里的 deb 安装，不要本地 `make install`。

```sh
# rootless（默认）
make clean && make package

# roothide（必须先 clean）
make clean && make package THEOS_PACKAGE_SCHEME=roothide
```

顶层 `Makefile` 用 `SUBPROJECTS = Tweak Prefs`，`make package` 一次构建全部（tweak dylib + prefs bundle + layout 资源）。

CI 通过 `.github/workflows/build.yml` 自动构建 rootless + roothide 双产物，push tag `v*` 触发 `release.yml` 创建 GitHub Release。

## 架构

```
Tweak.x (Logos 入口)
  ├─ dlopen MediaRemote.framework + dlsym 全部私有符号
  ├─ hook NCNotificationShortLookViewController viewWillAppear/viewWillDisappear
  ├─ CFNotificationCenter 监听 Darwin 通知 prefsChanged
  └─ 启动时序：UIApplicationDidFinishLaunching + 15s 兜底 fallback
       ↓
DIDisplayManager (单例，状态机 / 优先级 / timer)
  ├─ 优先级：通知 > 音乐（showingNotification 期间不更新音乐 UI）
  ├─ Timer 三件套：notificationTimer / reappearTimer / delayedHideTimer
  └─ 媒体控制：MRMediaRemoteSendCommand（playpause/next/prev）+ MRMediaRemoteSetElapsedTime（seek）
       ↓
DIWindow (UIWindowLevelStatusBar + 100，hitTest 穿透)
       ↓
DIContentView (状态机 UI：Hidden/Compact/Expanded/ExpandedFull × Media/Notification)
```

运行时数据流：`Tweak.x`（MediaRemote + 通知 hook）→ `DIDisplayManager`（状态机/优先级/timer）→ `DIWindow`（顶层窗口）→ `DIContentView`（岛 UI）。所有跨组件协调走 `DIDisplayManager.sharedInstance` 单例。

## 项目结构

```
DynamicIslandTweak/
├── Makefile                        # 顶层 Makefile（SUBPROJECTS = Tweak Prefs）
├── control                         # 包信息
├── Tweak/                          # 主 tweak 子项目
│   ├── Tweak.x                     # Logos 入口，MediaRemote + 通知 hook
│   ├── DIContentView.m/.h          # UI（状态机 / 动画 / 交互）
│   ├── DIDisplayManager.m/.h       # 单例，状态机 / 优先级 / timer
│   ├── DIWindow.m/.h               # 顶层窗口，触摸穿透
│   ├── DILocalization.m/.h         # 本地化
│   ├── DynamicIslandTweak.plist    # 注入 Filter（仅 com.apple.springboard）
│   └── Makefile                    # tweak.mk
├── Prefs/                          # 偏好 bundle 子项目（PSListController，saveAllPrefs / resetAllPrefs）
│   ├── DIRootListController.m/.h
│   ├── Resources/
│   │   ├── Root.plist              # 偏好面板 spec
│   │   ├── Info.plist
│   │   ├── en.lproj/               # 英文
│   │   └── zh-Hans.lproj/          # 简体中文
│   └── Makefile                    # bundle.mk
├── layout/
│   └── Library/PreferenceLoader/Preferences/
│       ├── DynamicIslandTweak.plist  # 内联偏好 spec（entry + items + PostNotification）
│       ├── icon.png / @2x / @3x      # 设置入口图标
│       ├── en.lproj/                 # 英文
│       └── zh-Hans.lproj/            # 简体中文
└── .github/workflows/              # build.yml + release.yml
```

## 私有 API 说明

Tweak 运行时通过 `dlopen` + `dlsym` 加载 `MediaRemote.framework` 私有符号，用最小化 `@interface` 声明 + `performSelector` / `respondsToSelector` 运行时探测通知内容字段（`title` / `message` / `header` / `icon`），失败安全降级。`私有头文件/`（中文目录名）存放 `NCNotificationShortLookViewController.h`、`NCNotificationRequest+Bulletin.h`、`NCNotificationViewController.h`、`LSApplicationWorkspace.h` 仅供参考，**Tweak.x 不 `#include` 它们**。

## 本地化

所有用户可见文案通过 `DILocalizedString(@"KEY")` 加载。新增 UI 文案须同步更新：

- `layout/Library/PreferenceLoader/Preferences/en.lproj/DynamicIslandTweak.strings`
- `layout/Library/PreferenceLoader/Preferences/zh-Hans.lproj/DynamicIslandTweak.strings`
- `Prefs/Resources/en.lproj/Localizable.strings`
- `Prefs/Resources/zh-Hans.lproj/Localizable.strings`

## 日志

- `DILog(fmt, ...)`：`syslog(LOG_NOTICE, "[DynamicIslandTweak] ...")` + `NSLog(@"[Tweak] ...")`
- `DIRawLog(fmt, ...)`：C 层 `syslog`，dyld 阶段可用
- 抓取：`idevicesyslog` / `oslog`（现代 iOS `NSLog` 不落盘、`/var/log/syslog` 不存在）
- 高频 hook（`syncTick`、`fetchNowPlayingInfo`）内禁重 IO

## 致谢

- [roothide/theos](https://github.com/roothide/theos) —— Theos fork，兼容官方 Theos 且支持 roothide scheme
- MediaRemote.framework 私有 API 参考来自 iOS 越狱社区逆向
- 通知 hook 灵感来自历史越狱通知项目

## License

MIT。本插件仅用于越狱环境下的互操作与个性化，请勿用于绕过付费内容、DRM 或其他违反法律与第三方服务条款的用途。

---

作者：DaFei
