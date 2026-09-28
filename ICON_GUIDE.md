# 设置图标尺寸指南

## 当前状态
- 现有 `layout/Library/PreferenceLoader/Preferences/icon.png` 是 141x129 的 JPEG 文件
- PreferenceLoader 需要标准 PNG 图标：29x29 (@1x), 58x58 (@2x), 87x87 (@3x)

## 推荐尺寸

PreferenceLoader 设置项图标标准：

| 文件名 | 尺寸 | 用途 |
|--------|------|------|
| icon.png | 29x29 | @1x 标准分辨率 (已过时，但兼容性保留) |
| icon@2x.png | 58x58 | @2x Retina 屏幕 (iPhone 6-8, SE 2/3) |
| icon@3x.png | 87x87 | @3x Super Retina (iPhone X 及以后) |

## 如何生成

### 方法 1: 在线工具
访问 [appicon.co](https://appicon.co) 或类似工具，上传原图自动生成所有尺寸

### 方法 2: ImageMagick (如果已安装)
```bash
cd layout/Library/PreferenceLoader/Preferences
convert icon.png -resize 29x29 icon-29.png
convert icon.png -resize 58x58 icon@2x.png
convert icon.png -resize 87x87 icon@3x.png
mv icon-29.png icon.png
```

### 方法 3: Photoshop / GIMP
1. 打开原图
2. 图像 → 图像大小 → 设置为目标尺寸（保持纵横比，居中裁剪）
3. 导出为 PNG-24（无透明度）或 PNG-8（如果是简单图标）

## 注意事项
- **必须是 PNG 格式**（当前是 JPEG，需转换）
- 建议设计为正方形，带圆角蒙版的效果由系统自动添加
- 背景色建议与插件主题一致（当前是灵动岛黑色背景）
- 图标内容在 70% 安全区域内，避免重要元素被圆角裁切

## 当前图标
现有图标尺寸不标准（141x129），建议：
1. 确认原图设计意图（保持 141x129 纵横比，还是裁剪为正方形）
2. 如果是正方形设计意图，裁剪为 141x141（或重新设计）
3. 生成标准 29/58/87 尺寸的 PNG 文件
4. 删除旧的 JPEG icon.png
