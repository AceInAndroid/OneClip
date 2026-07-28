# PasteLight 源码构建指南

PasteLight 是一款使用 Swift、SwiftUI 和 macOS 原生框架实现的轻量剪贴板历史工具。为保持现有工程和源码引用稳定，Xcode project、target、scheme 与源码目录仍使用内部名称 `OneClip`，实际应用产物为 `PasteLight.app`。

## 环境要求

- macOS 14.0+
- Xcode 15.0+
- Swift 5+

## 使用构建脚本

```bash
chmod +x build.sh
./build.sh
```

构建完成后，应用位于 `dist/PasteLight.app`。

## 使用 Xcode

1. 打开 `OneClip.xcodeproj`。
2. 选择 `OneClip` scheme。
3. 按 `⌘R` 运行，或按 `⌘B` 构建。

## 使用命令行

```bash
xcodebuild \
  -project OneClip.xcodeproj \
  -scheme OneClip \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

只构建单一架构时可以追加：

```bash
# Apple Silicon
ARCHS=arm64 ONLY_ACTIVE_ARCH=NO

# Intel
ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO
```

## 安装运行

```bash
cp -R dist/PasteLight.app /Applications/
open /Applications/PasteLight.app
```

直接粘贴功能需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 PasteLight。没有该权限时应用仍可记录历史、搜索和复制。

## 数据兼容性

应用显示名称改为 PasteLight，但仍保留原有 Bundle ID 与 `OneClip` 数据目录。这是有意的兼容设计，避免升级后丢失历史记录、偏好设置或系统权限关联。

## 项目结构

```text
src/
├── OneClip/                 # 主应用源码
├── OneClip.xcodeproj/       # Xcode 工程
├── OneClipTests/            # 单元测试
├── OneClipUITests/          # UI 测试
├── build.sh                 # 本地构建脚本
└── dist/                    # 本地产物目录
```

## 签名说明

本地构建默认使用 “Sign to Run Locally”。公开分发前应使用 Apple Developer ID 签名并完成公证。

## License

[MIT](../LICENSE)
