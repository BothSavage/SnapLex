enum ScreenRecordingStartPolicy {
    static func canStart(isCountingDown: Bool, isRecording: Bool, isFinalizing: Bool) -> Bool {
        !isCountingDown && !isRecording && !isFinalizing
    }
}
