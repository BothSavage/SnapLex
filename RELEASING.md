# GitHub Releases 配置

应用内更新使用 Sparkle 的 Ed25519 密钥验证更新清单和下载包。macOS 代码签名使用固定的「SnapLex Stable Code Signing」自签名证书，供 TCC 在各版本之间识别同一个应用。两把密钥用途不同，均不得提交到仓库。

固定证书不提供 Apple Developer ID 信任或公证。因此公开下载仍需在首次运行前按 [安装提示](docs/release-installation.md) 移除 quarantine。应用内更新的 Ed25519 验证仍会验证下载包来源。首次从 ad-hoc 签名的 1.0.4 迁移时，macOS 可能要求重新授权；此后持续使用同一证书、bundle ID `io.github.snaplex.app` 和同一安装位置，可避免每次更新重新设置权限。不要重建或替换签名证书；证书变更会改变 TCC 身份。

仓库的 `.github/workflows/ci.yml` 会在 `main` 分支推送和 Pull Request 上运行 `swift test`。发布工作流只在推送 `vMAJOR.MINOR.PATCH` tag 时运行。

## 首次配置自动发布

在拥有仓库写入权限的 Mac 上，先登录 GitHub CLI（`gh auth login`），然后在仓库根目录运行一次：

```bash
./scripts/setup_release_signing.sh
```

脚本会创建 10 年有效期的 RSA 代码签名证书，将其安装到当前用户登录钥匙串，并将 P12 和指纹写入 GitHub Actions Secrets / Variables。加密 P12 保存在 `~/Library/Application Support/SnapLex/Signing/`，访问密码保存在登录钥匙串。脚本检测到已有证书时会复用它，避免意外轮换。证书及私钥只由维护者和 GitHub Actions 持有。

还需在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 确认存在 Sparkle 更新签名 Secret：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `SNAPLEX_SIGNING_CERTIFICATE_P12_BASE64` | 设置脚本生成的自签名证书 `.p12` Base64 |
| Secret | `SNAPLEX_SIGNING_CERTIFICATE_PASSWORD` | 设置脚本生成的 `.p12` 密码 |
| Variable | `SNAPLEX_SIGNING_CERT_SHA1` | 设置脚本写入的证书 SHA-1 指纹；用于阻止无意换证 |
| Secret | `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle 更新签名私钥，与 Apple 账号无关 |

Sparkle 私钥当前存放在本机钥匙串，账号名为 `io.github.snaplex.updates`。安全备份并保管它：如果丢失，现有应用无法通过新密钥验证更新。不要将私钥提交到仓库、README 或 issue。

首次正式发布步骤：

1. 完成上述签名身份配置，并确认 `SPARKLE_EDDSA_PRIVATE_KEY` 已添加。
2. 将代码推送到 `main`，确认 `macOS CI` 检查通过。
3. 创建并推送三段式版本 tag，例如 `v1.0.5`。
4. GitHub Actions 使用固定自签名证书签署应用，构建未经公证的 DMG，生成经 Sparkle 签名的 `appcast.xml`，再创建正式 Release。
5. 用户按 [安装提示](docs/release-installation.md) 首次打开应用；之后可通过应用内更新安装新版。

发布正式版之前，检查器会提示 GitHub 尚无正式版；这属于正常状态。

## 手动打包与发布

完成首次设置后，本机 `./scripts/build_app.sh` 会优先使用登录钥匙串里的固定 SnapLex 证书。手动打包时应显式要求稳定签名：

```bash
SIGNING_KEYCHAIN="$HOME/Library/Application Support/SnapLex/Signing/SnapLex-Stable-Signing.keychain-db"
SIGNING_SHA1="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" | awk '/\"SnapLex Stable Code Signing\"/ { print $2; exit }')"
SNAPLEX_SIGN_IDENTITY="SnapLex Stable Code Signing" \
SNAPLEX_SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN" \
SNAPLEX_HARDENED_RUNTIME=1 \
SNAPLEX_REQUIRE_STABLE_SIGNING=1 \
SNAPLEX_EXPECTED_SIGNING_CERT_SHA1="$SIGNING_SHA1" \
./scripts/build_app.sh
```

将生成的 `dist/SnapLex.app` 放入名为 `SnapLex-版本号-macOS-架构-unnotarized.dmg` 的 DMG，再运行 `scripts/generate_appcast.sh 版本号 DMG路径 更新说明.md` 生成清单。脚本会拒绝 ad-hoc 签名，并可通过 `SNAPLEX_EXPECTED_SIGNING_CERT_SHA1` 验证使用的是固定证书。将 DMG 和 `appcast.xml` 一起上传到对应 Release。

如果替换证书，必须同时更新 GitHub Actions Variable `SNAPLEX_SIGNING_CERT_SHA1`，并预期用户需要重新授予 macOS 权限。Apple Development 证书可用于个人本机开发，但不能代替此发行身份；发布签名也不能改回 ad-hoc。
