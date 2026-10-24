# GitHub Releases 配置

应用内更新检查会读取 `BothSavage/SnapLex` 的最新正式版 Release。它只检查版本并打开发布页面；安装更新时由用户下载并替换应用，不会在后台覆盖应用。

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

密钥只应填入 GitHub Actions Secrets，不要提交到仓库、README、issue 或工作流文件。创建一个格式为 `vMAJOR.MINOR.PATCH` 的 tag（例如 `v1.2.3`）并推送后，GitHub Actions 会构建当前 runner 架构的应用、签名并公证 DMG，然后创建正式版 Release。应用内的“检查更新”随后会从 GitHub 发现它。

## 手动发布

没有配置上述 Apple 密钥时，工作流会在发布步骤前停止，不会创建未签名或未公证的正式版。可以先在 GitHub Releases 页面手动创建草稿；正式分发给用户前，应使用 Developer ID 签名并完成 Apple 公证。
