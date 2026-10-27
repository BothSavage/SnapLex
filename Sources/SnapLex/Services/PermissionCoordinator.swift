import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics

enum SnapLexPermission: String, CaseIterable, Identifiable {
    case screenRecording, accessibility, inputMonitoring, microphone
    var id: String { rawValue }
    var isOptional: Bool { self == .microphone }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制与系统声音"
        case .accessibility: "辅助功能"
        case .inputMonitoring: "输入监控"
        case .microphone: "麦克风"
        }
    }

    var description: String {
        switch self {
        case .screenRecording: "用于截图、录屏和录制系统声音"
        case .accessibility: "用于跨应用识别选中文本"
        case .inputMonitoring: "用于跨应用监听选择和录屏按键"
        case .microphone: "仅在录屏时选择麦克风后使用"
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        case .microphone: "mic.fill"
        }
    }

    var settingsURL: URL? {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .microphone: pane = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

enum SnapLexPermissionStatus: Equatable, Sendable {
    case checking, granted, needsSetup, notRequested, restricted
}

struct PermissionSnapshot: Equatable, Sendable {
    let screenRecording: SnapLexPermissionStatus
    let accessibility: SnapLexPermissionStatus
    let inputMonitoring: SnapLexPermissionStatus
    let microphone: SnapLexPermissionStatus

    subscript(_ permission: SnapLexPermission) -> SnapLexPermissionStatus {
        switch permission {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        case .microphone: microphone
        }
    }

    func shouldPresentAtStartup(optionalDeferred: Bool) -> Bool {
        SnapLexPermission.allCases.contains { permission in
            self[permission] != .granted && (!permission.isOptional || !optionalDeferred)
        }
    }

    static let checking = PermissionSnapshot(screenRecording: .checking, accessibility: .checking,
                                             inputMonitoring: .checking, microphone: .checking)
}

@MainActor
final class PermissionCoordinator: ObservableObject {
    static let shared = PermissionCoordinator()
    @Published private(set) var snapshot: PermissionSnapshot = .checking
    @Published private(set) var requesting: SnapLexPermission?
    @Published var guideReason: SnapLexPermission?
    private var refreshTask: Task<Void, Never>?
    private var refreshCallbacks: [(PermissionSnapshot) -> Void] = []
    private let readPermissions: @Sendable () -> PermissionSnapshot

    init(readPermissions: @escaping @Sendable () -> PermissionSnapshot = { PermissionCoordinator.readSnapshot() },
         observeActivation: Bool = true) {
        self.readPermissions = readPermissions
        if observeActivation {
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    static nonisolated func readSnapshot() -> PermissionSnapshot {
        let microphone: SnapLexPermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notRequested
        case .restricted: microphone = .restricted
        case .denied: microphone = .needsSetup
        @unknown default: microphone = .restricted
        }
        return PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .needsSetup,
            accessibility: AXIsProcessTrusted() ? .granted : .needsSetup,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .needsSetup,
            microphone: microphone
        )
    }

    func refresh(onComplete: ((PermissionSnapshot) -> Void)? = nil) {
        if let onComplete { refreshCallbacks.append(onComplete) }
        guard refreshTask == nil else { return }
        let readPermissions = self.readPermissions
        refreshTask = Task { [weak self] in
            let current = await Task.detached(priority: .utility) { readPermissions() }.value
            guard let self else { return }
            if self.snapshot != current { self.snapshot = current }
            self.refreshTask = nil
            let callbacks = self.refreshCallbacks
            self.refreshCallbacks.removeAll()
            callbacks.forEach { $0(current) }
        }
    }

    func request(_ permission: SnapLexPermission) {
        guard requesting == nil, snapshot[permission] != .restricted else { return }
        if snapshot[permission] == .granted { return }
        requesting = permission
        Task { [weak self] in
            switch permission {
            case .microphone where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                self?.openSettings(permission)
            case .screenRecording:
                let granted = await Task.detached { CGRequestScreenCaptureAccess() }.value
                if !granted { self?.openSettings(permission) }
            case .inputMonitoring:
                let granted = await Task.detached { CGRequestListenEventAccess() }.value
                if !granted { self?.openSettings(permission) }
            case .microphone:
                self?.openSettings(permission)
            }
            self?.requesting = nil
            self?.refresh()
        }
    }

    private func openSettings(_ permission: SnapLexPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
