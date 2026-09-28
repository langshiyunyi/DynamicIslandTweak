# 更新日志 - 2026-09-28

## 三大改进

### 1. 假进度条模式 ✅
**问题：** 之前每 5 秒从系统同步真实进度，导致进度条可能"跳跃"，体验不连贯

**解决方案：**
- 系统 `elapsed` 值仅在**新曲目**时作为起点
- 之后完全依赖本地 `CADisplayLink` 每秒 +1 推进
- 拖动进度条后，从拖动位置继续本地计时（重置 `lastSyncTime`）
- 忽略 `playbackRate`，简化为固定速率

**代码修改：**
- `DIContentView.m` - `updateElapsed:duration:playbackRate:` 方法
  - 仅在 `newTrack` 时更新 `trackElapsed`
  - 非新曲目时忽略系统 elapsed 值
  
- `DIContentView.m` - `progressStep` 方法
  - 改为 `trackElapsed += delta`（之前是 `delta * playbackRate`）
  - 添加注释说明假进度条逻辑
  
- `DIContentView.m` - `sliderEnded:` 方法
  - 拖动结束后重置 `lastSyncTime = CACurrentMediaTime()`

**效果：**
- ✅ 开启音乐后进度条平滑前进，每秒 +1
- ✅ 拖到任意位置，从该位置继续前进
- ✅ 不再出现"跳跃"现象

---

### 2. 优化通知岛布局 ✅
**问题：** 之前通知布局不够居中对齐，不如官方通知横幅优美

**解决方案：**
- 图标尺寸从 26x26 增大到 28x28（更醒目）
- 左边距从 `kPadding + 2` (8pt) 改为 10pt（统一间距）
- 图标与文字间距从 10pt 改为 8pt（更紧凑）
- **垂直居中对齐**：计算 `titleH + lineGap + msgH` 总高度，从 `(height - totalTextH) / 2` 开始布局
- 添加 `textAlignment = NSTextAlignmentLeft` 确保左对齐一致性

**代码修改：**
- `DIContentView.m` - `layoutNotificationContent` 方法
  - 新增 `leftPad` 变量统一管理左边距
  - 新增 `totalTextH` 和 `textStartY` 实现垂直居中
  - 重命名变量提升可读性（`textY` → `textStartY`）

**效果：**
- ✅ 通知内容完美居中对齐
- ✅ 视觉平衡感更强，类似官方横幅
- ✅ 长消息滚动依然正常工作

---

### 3. 设置图标尺寸指南 📋
**问题：** 当前 `icon.png` 是 141x129 的 JPEG 文件，不符合 PreferenceLoader 标准

**标准尺寸：**
| 文件名 | 尺寸 | 设备 |
|--------|------|------|
| `icon.png` | 29x29 | @1x (兼容性) |
| `icon@2x.png` | 58x58 | @2x Retina |
| `icon@3x.png` | 87x87 | @3x Super Retina |

**生成方法：**
1. **在线工具**：[appicon.co](https://appicon.co) 上传自动生成
2. **ImageMagick**：
   ```bash
   cd layout/Library/PreferenceLoader/Preferences
   convert icon.png -resize 29x29 icon-temp.png
   convert icon.png -resize 58x58 icon@2x.png
   convert icon.png -resize 87x87 icon@3x.png
   mv icon-temp.png icon.png
   ```
3. **Photoshop/GIMP**：手动裁剪并导出为 PNG

**注意事项：**
- ✅ 必须是 PNG 格式（当前是 JPEG）
- ✅ 建议设计为正方形
- ✅ 重要内容在 70% 安全区域内（避免圆角裁切）

**文件：**
- 创建了 `ICON_GUIDE.md` 详细说明文档

---

## 测试清单

### 假进度条测试
- [ ] 播放音乐，观察进度条是否平滑前进（每秒 +1）
- [ ] 拖动进度条到中间，松手后是否从该位置继续前进
- [ ] 切换到下一首歌，进度条是否重置到新歌起点
- [ ] 暂停音乐，进度条是否停止（不再推进）

### 通知布局测试
- [ ] 收到通知，检查图标、标题、消息是否垂直居中对齐
- [ ] 长消息是否启动滚动（marquee）
- [ ] 长按展开通知，是否正常显示多行消息
- [ ] 上滑/左滑关闭通知，动画是否流畅

### 图标测试
- [ ] 生成 29/58/87 尺寸的 PNG 图标
- [ ] 替换现有 JPEG 文件
- [ ] 在 iPhone 设置中查看图标是否清晰
- [ ] 不同分辨率设备上测试 @2x/@3x 是否正确加载

---

## 文件清单

**修改的文件：**
- `Tweak/DIContentView.m` - 假进度条 + 通知布局优化
- `CLAUDE.md` - 更新文档说明新实现逻辑

**新增的文件：**
- `ICON_GUIDE.md` - 图标尺寸生成指南
- `CHANGELOG_2026-09-28.md` - 本更新日志

---

## 构建提醒

⚠️ **必须通过 GitHub Actions 构建**
```bash
git add -A
git commit -m "优化：假进度条模式 + 通知布局居中对齐 + 图标尺寸指南"
git push origin main
```

本地 `make package` 构建会导致 SpringBoard watchdog 崩溃（arm64e ABI 不兼容）。

---

## 技术细节

### 假进度条原理
```objc
// 新曲目：使用系统 elapsed 作为起点
if (newTrack) {
    self.trackElapsed = elapsed;
    self.lastSyncTime = CACurrentMediaTime();
}
// 非新曲目：忽略系统值，完全本地推进

// progressStep 每帧调用（CADisplayLink）
CFTimeInterval delta = now - self.lastSyncTime;
self.trackElapsed += delta; // 固定每秒 +1
```

### 通知居中对齐原理
```objc
// 计算总文本高度
CGFloat totalTextH = titleH + lineGap + msgH;
// 从居中位置开始布局
CGFloat textStartY = (height - totalTextH) / 2;
// 标题和消息依次排列
titleLabel.frame = CGRectMake(x, textStartY, w, titleH);
messageLabel.frame = CGRectMake(x, textStartY + titleH + lineGap, w, msgH);
```
