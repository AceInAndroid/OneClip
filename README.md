<p align="right">
  <b>中文</b> · <a href="README_EN.md">English</a>
</p>

<div align="center">
  <img src="src/OneClip/Assets.xcassets/AppIcon.appiconset/icon-256.png" alt="PasteLight 图标" width="112" height="112">
  <h1>PasteLight</h1>
  <p><strong>轻一点，快一点，粘贴一步到位。</strong></p>
  <p>原生、轻量、专注的 macOS 剪贴板历史工具。</p>
</div>

<p align="center">
  <a href="https://github.com/AceInAndroid/OneClip/releases/latest"><img src="https://img.shields.io/github/v/release/AceInAndroid/OneClip?style=flat-square&color=5E6AD2" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-Native-F05138?style=flat-square&logo=swift&logoColor=white" alt="Native SwiftUI">
  <img src="https://img.shields.io/badge/Data-Local-22C55E?style=flat-square" alt="Local Data">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-F59E0B?style=flat-square" alt="MIT License"></a>
</p>

## 为什么是 PasteLight

PasteLight 不想成为一个常驻屏幕的复杂工作台。它安静地待在菜单栏，只在你按下快捷键时出现，帮你找到刚才复制过的内容，然后立刻回到手头的工作。

- **轻量呈现**：默认从屏幕底部弹出横向历史栏，用完即隐藏；也可切换为经典窗口。
- **轻量交互**：单击选择，双击直接粘贴；方向键移动焦点，回车复制所选项。
- **轻量搜索**：无需先点搜索框，直接输入即可搜索；也支持 `⌘F`。
- **轻量存储**：数据保存在本机，重复内容自动合并，历史可按天自动清理。
- **轻量技术栈**：使用 Swift、SwiftUI 与 macOS 原生框架构建，没有网页运行时。

## 核心能力

### 快速粘贴

- 默认快捷键 `⌘⇧V`，可在设置中修改。
- 支持文本、图片、文件以及常见媒体和文档类型。
- 双击项目后恢复原应用，并将内容粘贴到当前光标位置。
- 粘贴完成的项目会在窗口隐藏后移到首位，不打断当前视觉操作。
- 未授予辅助功能权限时安全降级为复制到剪贴板。

### 找到需要的内容

- 打开面板后直接输入字母或中文即可进入搜索。
- `⌘F` 显示搜索框并获得焦点。
- 支持拼音输入法确认流程，退出搜索后可继续使用方向键。
- 按文本、图片、文件等类型快速筛选。

### 管理历史记录

- 相同文本、图片或文件不会重复堆积。
- 可选保留 `7 / 14 / 30 / 60 / 180 / 365` 天或永久保留，默认 60 天。
- 收藏内容不会被自动清理。
- 复制、粘贴、收藏、搜索和删除集中在原生右键菜单中。

### 两种界面

- **底部弹窗**：默认布局，横向滚动，适合快速选择。
- **经典窗口**：纵向列表，适合浏览较长的历史记录。

两种布局都采用原生材质和克制的 Liquid Glass 视觉，并保持相同的键盘、搜索与粘贴行为。

## 下载与安装

前往 [Releases](https://github.com/AceInAndroid/OneClip/releases/latest) 下载与你的 Mac 对应的安装包：

- `arm64.dmg`：Apple Silicon（M1、M2、M3、M4 及后续芯片）
- `x86_64.dmg`：Intel Mac

打开 DMG，将 `PasteLight.app` 拖入 `Applications` 文件夹即可。

> 当前社区构建使用本地签名，尚未进行 Apple Developer ID 公证。macOS 如果阻止首次打开，请前往“系统设置 → 隐私与安全性”，确认仍要打开来自可信来源的应用。

## 辅助功能权限

PasteLight 只有在执行“直接粘贴到当前光标位置”时才需要辅助功能权限。剪贴板历史、搜索和手动复制不依赖该权限。

1. 打开 PasteLight 的授权引导。
2. 进入“系统设置 → 隐私与安全性 → 辅助功能”。
3. 将 `PasteLight.app` 加入列表并打开开关。

授权后，双击历史项目即可回到之前的应用并直接粘贴。

## 数据与隐私

- 剪贴板历史保存在本机，不会上传到云端。
- 图片和大文件按需读取，减少常驻内存占用。
- 内容指纹用于本地去重，不会离开设备。
- 改名后仍沿用原有 Bundle ID 和数据目录，现有用户的历史记录与设置可以继续使用。

## 从源码构建

要求：macOS 14+、Xcode 15+。

```bash
git clone https://github.com/AceInAndroid/OneClip.git
cd OneClip/src
xcodebuild \
  -project OneClip.xcodeproj \
  -scheme OneClip \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Xcode target 和 scheme 暂时保留内部名称 `OneClip`，构建产物为 `PasteLight.app`。更多说明见 [源码构建指南](src/README.md)。

## 快捷操作

| 操作 | 默认方式 |
| --- | --- |
| 显示或隐藏 PasteLight | `⌘⇧V` |
| 选择项目 | 单击 / 方向键 |
| 粘贴项目 | 双击 |
| 复制选中项目 | 回车 |
| 开始搜索 | 直接输入 / `⌘F` |
| 快速复制前 9 项 | `⌘1`–`⌘9` |
| 更多操作 | 右键项目 |
| 打开设置 | `⌘,` |

## 参与贡献

Bug 与功能建议可以提交到 [Issues](https://github.com/AceInAndroid/OneClip/issues)。提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## License

[MIT](LICENSE)
