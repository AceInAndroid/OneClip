# 贡献指南

感谢你对 PasteLight 的关注！欢迎提交 Issue 和 Pull Request。

## 如何贡献

### 报告 Bug

1. 在 [Issues](https://github.com/AceInAndroid/OneClip/issues) 中搜索是否已有相同问题
2. 如果没有，创建新 Issue，包含：
   - macOS 版本
   - PasteLight 版本
   - 问题描述和复现步骤
   - 错误日志（如有）

### 提交代码

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/your-feature`
3. 提交更改：`git commit -m '添加某功能'`
4. 推送分支：`git push origin feature/your-feature`
5. 创建 Pull Request

### 代码规范

- 使用 Swift 官方代码风格
- 保持代码简洁，添加必要注释
- 新功能需要添加对应测试
- 提交信息使用中文，简洁明了

### 开发环境

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

### 构建项目

```bash
cd src
./build.sh
```

## 项目结构

```
src/
├── OneClip/                 # 主应用源码
│   ├── ClipboardManager.swift   # 剪贴板管理核心
│   ├── ClipboardStore.swift     # 数据存储
│   ├── ContentView.swift        # 主界面
│   ├── SettingsManager.swift    # 设置管理
│   └── ...
├── OneClipTests/            # 单元测试
└── OneClipUITests/          # UI 测试
```

## 联系方式

- 邮箱：vip@oneclip.cloud
- QQ 群：[1060157293](https://qm.qq.com/q/xiImGHVMcM)

感谢你的贡献！🎉
