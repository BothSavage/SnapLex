## 安装提示 / Installation note

SnapLex 后续版本使用固定的自签名代码证书，macOS 可以据此保留应用更新前授予的权限。从 ad-hoc 签名的 1.0.4 切换到固定证书版本时，系统可能要求重新授权一次；之后相同证书签发的更新通常不需要重复设置。该版本未经 Apple 公证，首次打开时 macOS 可能阻止运行。确认应用来自可信的 SnapLex 发布页后，将 `SnapLex.app` 放入「应用程序」，在终端执行：

```bash
sudo xattr -rd com.apple.quarantine /Applications/SnapLex.app
```

系统提示输入当前 Mac 用户的管理员密码时，终端不会显示任何字符或星号，直接输入完成后按回车即可。如果应用放在其他位置，请使用实际路径，例如 `~/Downloads/SnapLex.app`。也可以输入 `sudo xattr -rd com.apple.quarantine `（末尾有空格），把应用图标拖入终端后按回车。

SnapLex releases use a fixed self-signed code-signing certificate so macOS can preserve permissions across updates. Moving from the ad-hoc-signed 1.0.4 release may require granting permissions once; updates signed with the same certificate should not require repeating that setup. The app is not notarized, so macOS may block the first launch. Confirm that the download came from the trusted SnapLex release page, then run the command above after moving it to Applications. Enter your Mac administrator password when prompted: the terminal will show no characters or asterisks while you type. Press Return when finished. If the app is elsewhere, replace the path with its actual location, or drag the app into Terminal after typing the command and a trailing space.
