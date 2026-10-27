import AppKit
import Combine
import Sparkle

/// Sparkle authenticates the release feed and archive before it replaces the app.
@MainActor
final class NativeUpdateInstaller: NSObject, ObservableObject, SPUUserDriver {
    static let shared = NativeUpdateInstaller()
    enum State: Equatable {
        case idle
        case checking
        case downloading(Double?)
        case preparing(Double?)
        case ready
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var updater: SPUUpdater?
    private var expectedVersion: String?
    private var cancelDownload: (() -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var lastProgressPercent = -1

    var canCancel: Bool { cancelDownload != nil }

    var isBusy: Bool {
        switch state {
        case .idle, .failed: return false
        default: return true
        }
    }

    func download(version: String) {
        guard updater == nil else { return }
        expectedVersion = version
        state = .checking
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            self.updater = nil
            state = .failed(error.localizedDescription)
        }
    }

    func installAndRestart() {
        guard let reply = installReply else { return }
        installReply = nil
        (NSApp.delegate as? AppDelegate)?.allowTerminationForUpdate()
        state = .installing
        reply(.install)
    }

    func cancel() {
        cancelDownload?()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { cancelDownload = cancellation; state = .checking }
    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate, appcastItem.displayVersionString == expectedVersion else {
            state = .failed(L10n.string("暂时无法安全安装此版本，请稍后重试。"))
            reply(.dismiss)
            return
        }
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = .failed(error.localizedDescription)
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = .failed(error.localizedDescription)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        expectedBytes = 0; receivedBytes = 0
        lastProgressPercent = -1
        state = .downloading(nil)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        let progress = min(1, Double(receivedBytes) / Double(expectedBytes))
        let percent = Int(progress * 100)
        guard percent != lastProgressPercent else { return }
        lastProgressPercent = percent
        state = .downloading(progress)
    }
    func showDownloadDidStartExtractingUpdate() { cancelDownload = nil; lastProgressPercent = -1; state = .preparing(nil) }
    func showExtractionReceivedProgress(_ progress: Double) {
        let bounded = min(1, max(0, progress))
        let percent = Int(bounded * 100)
        guard percent != lastProgressPercent else { return }
        lastProgressPercent = percent
        state = .preparing(bounded)
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { installReply = reply; state = .ready }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { state = .installing }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        cancelDownload = nil
        installReply = nil
        updater = nil
        if case .failed = state { return }
        state = .idle
    }
}
