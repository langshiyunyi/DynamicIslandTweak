# 设置界面重构 - 2026-09-28

## 主要改进

### 1. ✅ 移除"使用激进封面 API"选项
- 从高级设置中删除 `useOptionalArtwork` 选项
- 简化设置界面，移除不必要的高级功能

### 2. 🎨 全新的子页面分类结构
使用 PSChildPaneSpecifier 重构设置界面，采用三大分类：

#### 🎵 音乐岛 (MusicIsland.plist)
- **位置设置**：Y 偏移量
- **紧凑模式尺寸**：宽度、高度
- **展开模式尺寸**：宽度
- **完全展开模式尺寸**：宽度、高度
- **圆角半径**：音乐岛专属圆角设置
- **跑马灯动画**：
  - 样式选择：平滑 / 弹跳 / 波浪
  - 速度调节：0.1 - 2.0
- **行为设置**：重新出现延迟

#### 🔔 消息岛 (NotificationIsland.plist)
- **基本设置**：启用/禁用通知岛
- **紧凑尺寸**：默认宽度 340、高度 43
- **展开尺寸**：展开宽度 370、高度 90
- **图标自定义**：
  - 图标大小：20 - 40 (默认 28)
  - 左边距：5 - 20 (默认 10)
  - 图标圆角：0 - 20 (默认 6)
- **文字布局**：
  - 图标与文字间距：5 - 20 (默认 8)
  - 标题与消息行间距：0 - 10 (默认 2)
- **圆角半径**：通知岛专属圆角设置
- **行为设置**：通知显示时长 1 - 30 秒
- **跑马灯动画**：
  - 样式选择：平滑 / 弹跳 / 波浪
  - 速度调节：0.1 - 2.0

#### ⚙️ 其他设置 (OtherSettings.plist)
- **边框设置**：启用、宽度、RGB 颜色
- **高级设置**：详细日志开关

### 3. 🎭 三种跑马灯动画样式

#### 平滑模式 (Smooth - 默认)
```objc
// 匀速水平滚动，无任何抖动
self.marqueeLabel.frame = CGRectMake(x, y, width, height);
```

#### 弹跳模式 (Bounce)
```objc
// 使用 sin 曲线产生上下弹跳效果
CGFloat bounceAmplitude = 3.0; // 音乐岛
CGFloat bounceAmplitude = 2.5; // 通知岛
CGFloat progress = offset / totalW;
CGFloat bounceY = y + sin(progress * M_PI * 4) * bounceAmplitude;
```

#### 波浪模式 (Wave)
```objc
// 持续波浪起伏，基于实时时间
CGFloat waveAmplitude = 2.5; // 音乐岛
CGFloat waveAmplitude = 2.0; // 通知岛
CGFloat time = CACurrentMediaTime();
CGFloat waveY = y + sin(time * 3.0 + offset * 0.15) * waveAmplitude;
```

**效果对比：**
- **平滑**：最流畅，适合长时间观看
- **弹跳**：节奏感强，有活力，幅度较大（音乐岛 3.0 / 通知岛 2.5）
- **波浪**：连续起伏，优雅动感，幅度适中（音乐岛 2.5 / 通知岛 2.0）

### 4. 📐 通知岛完全自定义

所有参数都可以精细调节：
- **尺寸**：紧凑宽 200-400、高 35-70；展开宽 300-410、高 70-200
- **图标**：大小 20-40、左边距 5-20、圆角 0-20
- **布局**：图标文字间距 5-20、行间距 0-10
- **圆角**：0-40 独立设置
- **行为**：显示时长 1-30 秒

### 5. 🎨 动态参数应用

代码中所有硬编码的布局参数已替换为配置变量：

**之前（硬编码）：**
```objc
CGFloat iconS = 28;
CGFloat leftPad = 10;
CGFloat textGap = 8;
CGFloat lineGap = 2;
```

**现在（动态配置）：**
```objc
CGFloat iconS = _prefNotifIconSize;
CGFloat leftPad = _prefNotifIconLeftPad;
CGFloat textGap = _prefNotifTextLeftGap;
CGFloat lineGap = _prefNotifLineGap;
self.notifIconView.layer.cornerRadius = _prefNotifIconCornerRadius;
```

## 文件结构

### 新增文件
```
Prefs/Resources/
├── MusicIsland.plist          # 音乐岛子页面
├── NotificationIsland.plist   # 消息岛子页面
└── OtherSettings.plist        # 其他设置子页面
```

### 修改文件
```
Prefs/Resources/
├── Root.plist                                  # 精简为主页面（3个子页面入口）
├── en.lproj/Localizable.strings               # 新增 40+ 本地化字符串
├── zh-Hans.lproj/Localizable.strings          # 新增 40+ 中文字符串
└── (删除) layout/Library/PreferenceLoader/Preferences/
   ├── en.lproj/DynamicIslandTweak.strings      # 需要同步更新
   └── zh-Hans.lproj/DynamicIslandTweak.strings # 需要同步更新

Tweak/
└── DIContentView.m            # 新增动态参数、跑马灯样式实现
```

## 代码统计

**新增配置项：** 13 个
```objc
// 音乐岛
_prefMarqueeStyle = 0;
_prefMarqueeSpeed = 0.5;

// 通知岛
_prefNotifCompactW = 340.0;
_prefNotifCompactH = 43.0;
_prefNotifExpandedW = 370.0;
_prefNotifExpandedH = 90.0;
_prefNotifIconSize = 28.0;
_prefNotifIconLeftPad = 10.0;
_prefNotifIconCornerRadius = 6.0;
_prefNotifTextLeftGap = 8.0;
_prefNotifLineGap = 2.0;
_prefNotifMarqueeStyle = 0;
_prefNotifMarqueeSpeed = 0.5;
```

**新增本地化字符串：** 42 个（英文 + 中文各 42）

## 测试清单

### 子页面导航
- [ ] 主页面显示 3 个子页面入口
- [ ] 点击"🎵 音乐岛"进入音乐岛设置
- [ ] 点击"🔔 消息岛"进入消息岛设置
- [ ] 点击"⚙️ 其他设置"进入其他设置
- [ ] 所有子页面都能正常返回主页面

### 音乐岛设置
- [ ] 调整尺寸参数，音乐岛大小随之变化
- [ ] 修改圆角半径，立即生效
- [ ] 选择跑马灯样式：平滑 / 弹跳 / 波浪
- [ ] 调整跑马灯速度，滚动速度改变
- [ ] 长歌名触发跑马灯，能看到选择的动画效果

### 消息岛设置
- [ ] 调整紧凑尺寸，通知岛大小改变
- [ ] 长按展开通知，展开尺寸参数生效
- [ ] 修改图标大小，图标尺寸改变
- [ ] 调整左边距和文字间距，布局改变
- [ ] 修改行间距，标题与消息间距改变
- [ ] 调整图标圆角，图标形状改变
- [ ] 选择通知跑马灯样式，长消息滚动效果改变
- [ ] 修改通知显示时长，自动消失时间改变

### 跑马灯动画
- [ ] 平滑样式：匀速水平滚动，无抖动
- [ ] 弹跳样式：有明显上下弹跳（幅度 2.5-3.0）
- [ ] 波浪样式：连续波浪起伏（幅度 2.0-2.5）
- [ ] 速度调节生效（0.1 慢速 → 2.0 快速）
- [ ] 音乐岛和消息岛分别独立设置

### 其他设置
- [ ] 边框开关、宽度、颜色调节正常
- [ ] 详细日志开关正常

### 保存与重置
- [ ] "保存设置"按钮写入所有参数
- [ ] "恢复默认值"按钮恢复所有默认值
- [ ] 重启 SpringBoard 后参数保持

## 升级指南

### 对于用户
1. 更新插件后，原有设置**不受影响**（向后兼容）
2. 主页面现在只有 3 个分类入口，更清晰
3. 进入"音乐岛"或"消息岛"页面调整详细参数
4. 尝试新的跑马灯动画样式

### 对于开发者
1. 新增参数都有默认值，不影响现有功能
2. `reloadPrefs` 方法已更新，加载所有新参数
3. 跑马灯样式通过 `_prefMarqueeStyle` / `_prefNotifMarqueeStyle` 控制
4. 通知布局使用动态参数，完全可配置

## 已知问题

无

## 后续计划

- [ ] 添加更多跑马灯样式（渐变、闪烁等）
- [ ] 支持自定义通知图标圆角样式（圆形/方形/Squircle）
- [ ] 添加颜色选择器替代 RGB 滑块
- [ ] 支持主题预设（一键切换样式）

---

**兼容性：** iOS 15.0+  
**测试环境：** roothide + Procursus theos  
**构建方式：** 仅支持 GitHub Actions 远程构建
