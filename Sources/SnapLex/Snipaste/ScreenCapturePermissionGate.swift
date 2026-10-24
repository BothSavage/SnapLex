/// Checks screen capture permission before any capture UI is shown.
/// The closures keep the ordering deterministic in unit tests.
enum ScreenCapturePermissionGate {
    static func ensureAccess(
        preflight: () -> Bool,
        request: () -> Bool
    ) -> Bool {
        guard !preflight() else { return true }

        // Request may wait for the user or may return while macOS is showing
        // its permission prompt. In either case, never show the capture panel
        // until a fresh preflight confirms access.
        _ = request()
        return preflight()
    }
}
