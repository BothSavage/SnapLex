# GitHub Releases 配置

应用内更新检查会读取 `BothSavage/SnapLex` 的最新正式版 Release。它只检查版本并打开发布页面；安装更新时由用户下载并替换应用，不会在后台覆盖应用。普通 Git tag 不会显示为可更新版本，必须先发布正式版 Release。

仓库的 `.github/workflows/ci.yml` 会在 `main` 分支推送和 Pull Request 上运行 `swift test`。发布工作流只在推送 `vMAJOR.MINOR.PATCH` tag 时运行。

## 启用自动发布

仓库已包含 `.github/workflows/release.yml`。在 GitHub 仓库的 **Settings → Secrets and variables → Actions → New repository secret** 中添加以下仓库密钥：

| Secret | 内容 |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Developer ID Application 证书 `.p12` 文件的 Base64 内容 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | Keychain 中证书的完整签名身份名称 |
| `APPLE_ID` | 用于 Apple 公证的 Apple Account 邮箱 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 该 Apple Account 的 app-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

密钥只应填入 GitHub Actions Secrets，不要提交到仓库、README、issue 或工作流文件。

首次正式发布步骤：

1. 在 **Settings → Secrets and variables → Actions** 添加上表中的六个 Secret。
2. 将代码推送到 `main`，确认 `macOS CI` 检查通过。
3. 创建并推送一个三段式版本 tag，例如 `v1.2.3`。
4. GitHub Actions 会构建当前 runner 架构的应用、签名并公证 DMG，然后创建正式版 Release。
5. 用户在应用内点“检查更新”后，会看到新版本和说明，并可打开 Release 页面下载 DMG。

发布正式版之前，检查器会提示 GitHub 尚无正式版；这属于正常状态。

## 手动发布

没有配置上述 Apple 密钥时，工作流会在发布步骤前停止，不会创建未签名或未公证的正式版。可以先在 GitHub Releases 页面手动创建草稿；正式分发给用户前，应使用 Developer ID 签名并完成 Apple 公证。
