import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PermissionGuideWindow: NSObject, NSWindowDelegate {
    static let shared = PermissionGuideWindow()
    private var window: NSWindow?
    private var refreshTimer: Timer?

    func show(focusing permission: SnapLexPermission? = nil) {
        PermissionCoordinator.shared.guideReason = permission
        if window == nil {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            let height = min(530, max(300, (screen?.visibleFrame.height ?? 578) - 48))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
                                styleMask: [.titled, .closable, .miniaturizable],
                                backing: .buffered, defer: false)
            panel.title = L10n.string("权限设置")
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
            let hosting = NSHostingView(rootView: PermissionGuideView())
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 500, height: height)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            panel.delegate = self
            if let screen {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - panel.frame.width - 24),
                                             y: visible.minY + 24))
            } else {
                panel.center()
            }
            window = panel
        }
        PermissionCoordinator.shared.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in PermissionCoordinator.shared.refresh() }
            }
        }
    }

    func close() {
        stopRefreshing()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { stopRefreshing() }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

struct PermissionGuideView: View {
    @ObservedObject private var permissions = PermissionCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("准备好使用 SnapLex"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(L10n.string(permissions.guideReason == .microphone
                                     ? "开启麦克风权限后，请重新开始录屏。"
                                     : "检查所需权限，让截图和划词正常工作。"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            PermissionStatusList()

            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.string("在系统设置中找到 SnapLex 并打开开关。若未出现，可将下方图标拖入列表。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
                        .resizable().frame(width: 27, height: 27)
                    Text("SnapLex").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "hand.draw").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .accessibilityLabel(L10n.string("拖动 SnapLex 到系统设置"))
                HStack {
                    Text(L10n.string("部分权限开启后可能需要重新启动 SnapLex。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("重启 SnapLex")) {
                        (NSApp.delegate as? AppDelegate)?.restartApp()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
                }
            }
            HStack {
                Text(L10n.string("麦克风是可选的，可稍后设置。"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("稍后设置")) {
                    UserDefaults.standard.set(true, forKey: "SnapLex.permissionGuideOptionalDeferred")
                    PermissionGuideWindow.shared.close()
                }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("完成")) { PermissionGuideWindow.shared.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
    }
}

struct PermissionStatusList: View {
    @ObservedObject private var permissions = PermissionCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SnapLexPermission.allCases.enumerated()), id: \.element.id) { index, permission in
                permissionRow(permission)
                if index < SnapLexPermission.allCases.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.025),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private func permissionRow(_ permission: SnapLexPermission) -> some View {
        let status = permissions.snapshot[permission]
        let canRequest = status != .granted && status != .restricted && status != .checking
        return Button {
            permissions.request(permission)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: permission.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(L10n.string(permission.title)).font(.system(size: 13, weight: .medium))
                        if permission.isOptional {
                            Text(L10n.string("可选")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.string(permission.description))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if permissions.requesting == permission {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.string(statusLabel(status)))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(status == .granted ? Color.green : (canRequest ? Color.blue : Color.secondary))
                    if canRequest { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRequest || permissions.requesting != nil)
        .accessibilityHint(canRequest ? L10n.string("打开系统权限设置") : "")
    }

    private func statusLabel(_ status: SnapLexPermissionStatus) -> String {
        switch status {
        case .checking: "正在检查"
        case .granted: "已开启"
        case .needsSetup: "去设置"
        case .notRequested: "去授权"
        case .restricted: "受系统限制"
        }
    }
}
