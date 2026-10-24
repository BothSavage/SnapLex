<div align="center">

**简体中文** · [English](README.en.md)

<img src="Assets/AppIcon-1024.png" width="104" alt="SnapLex 应用图标">

# SnapLex

### 截图、标注、贴图与划词翻译，一套顺手完成

一款为 macOS 打造的原生效率工具。把屏幕内容快速变成可编辑、可查阅、可继续使用的信息。

[功能一览](#功能一览) · [安装与运行](#安装与运行) · [权限说明](#权限说明) · [隐私](#隐私) · [参与开发](#参与开发)

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org/)
[![macOS CI](https://github.com/BothSavage/SnapLex/actions/workflows/ci.yml/badge.svg)](https://github.com/BothSavage/SnapLex/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

SnapLex 将屏幕捕捉和语言学习工具放在同一个原生 macOS 应用中：截取并标注屏幕、把参考内容钉在桌面、录制操作过程，或选中陌生文本立即查看翻译。翻译记录、词频统计和截图历史也都可以在应用主页中管理。

## 功能一览

### 屏幕捕捉与标注

- 区域截图支持窗口识别、选区调整、取色、放大镜和标注。
- 标注工具包括形状、箭头、画笔、马赛克、模糊、序号和文字；标注后仍可移动、缩放和旋转。
- 使用 Apple Vision 分离主体或虚化背景，并可识别截图中的文字和二维码、条形码。
- 滚动长截图支持边滚动边拼接；完成后可继续编辑、复制或贴图。

### 桌面贴图与屏幕录制

- 将截图、剪贴板图片或文字钉在桌面上，方便对照资料；支持缩放、透明度和鼠标穿透。
- 使用 ScreenCaptureKit 录制区域、窗口或整个屏幕，并导出 MP4 或 GIF。
- 最近截图会自动保存到截图历史，可按设置的数量保留和清理。

### 划词翻译与学习记录

- 在其他应用中选中文字后呼出翻译控制条，也可用快捷键触发。
- 可选择 Google 翻译或 macOS 提供的 Apple 原生翻译。
- 通过 macOS 系统词典查看释义，支持朗读英文原词。
- 自动收集划词与截图翻译记录；按日期查看翻译趋势、词频和单词上下文，也可设置忽略词。

### 偏好设置

- 支持简体中文、繁体中文、English、日语、韩语、法语和德语界面。
- 可自定义全局快捷键、设置登录时启动，并分别控制两类翻译是否写入记录。
- 应用内可检查 GitHub Releases 上的最新正式版并查看版本说明；用户从发布页确认下载和安装，不会静默覆盖应用。

## 安装与运行

### 下载

正式版发布后，可从 [GitHub Releases](https://github.com/BothSavage/SnapLex/releases/latest) 下载 macOS 安装包。

### 从源码构建

需要 macOS 15 或更新版本，以及 Swift 5.10+。安装 Xcode Command Line Tools 后运行：

```bash
git clone https://github.com/BothSavage/SnapLex.git
cd SnapLex
./scripts/build_app.sh
open ./dist/SnapLex.app
```

## 权限说明

SnapLex 会在对应功能首次使用时请求 macOS 权限：

- **屏幕录制**：截图、滚动截图和屏幕录制。
- **辅助功能**：跨应用划词检测和部分全局快捷键。
- **麦克风**：仅在录屏时选择录入麦克风声音后使用。

## 隐私

截图、截图历史和翻译记录保存在本机。选择 Google 翻译时，待翻译文本会发送给 Google；选择 Apple 原生翻译时，由 macOS 的 Translation 框架处理。应用不会把这些内容上传到 SnapLex 自有服务器。你可以在偏好设置中分别关闭划词翻译和截图翻译的自动记录。

## 参与开发

欢迎提交问题反馈和改进建议。发布流程、签名和公证所需的 GitHub Actions 配置见 [RELEASING.md](RELEASING.md)。

## 开源协议

SnapLex 使用 [MIT License](LICENSE)。
