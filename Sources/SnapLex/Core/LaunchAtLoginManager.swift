import Foundation
import Combine
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled = false
    @Published public private(set) var errorMessage: String?

    private init() {
        refreshStatus()
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshStatus()
    }

    public func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
    }
}
