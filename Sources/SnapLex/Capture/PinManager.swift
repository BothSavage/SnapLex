import Foundation
import AppKit
import ImageIO
import SwiftUI
import Translation

public struct PinHistoryRecord: Identifiable {
    public let id = UUID()
    public var image: NSImage { storage.loadImage() ?? NSImage(size: storage.imageSize) }
    public let frame: NSRect
    public let closedAt: Date
    fileprivate let storage: ClosedPinImage

    @MainActor
    init(image: NSImage, frame: NSRect, closedAt: Date) {
        self.storage = ClosedPinImage(image)
        self.frame = frame
        self.closedAt = closedAt
    }
}

/// Private backing cannot be invalidated by screenshot-history deletion or
/// retention. The serial queue orders writes, restores, and cleanup.
fileprivate final class ClosedPinImage: @unchecked Sendable {
    static let ioQueue = DispatchQueue(label: "io.github.snaplex.closed-pins", qos: .utility)
    let imageSize: NSSize
    let decodedBytes: Int
    private let lock = NSLock()
    private var residentImage: NSImage?
    private var isSpilling = false
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapLex-ClosedPin-\(UUID().uuidString)", isDirectory: true)
    private var terminationObserver: NSObjectProtocol?

    @MainActor
    init(_ image: NSImage) {
        imageSize = image.size
        residentImage = image
        // Account for all bitmap representations, including Retina images.
        let bitmapBytes = image.representations.compactMap { $0 as? NSBitmapImageRep }.reduce(0) { total, rep in
            let bytes = rep.bytesPerRow.multipliedReportingOverflow(by: rep.pixelsHigh)
            let sum = total.addingReportingOverflow(bytes.overflow ? Int.max : bytes.partialValue)
            return sum.overflow ? Int.max : sum.partialValue
        }
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let cgBytes = cgImage.map { $0.bytesPerRow.multipliedReportingOverflow(by: $0.height) }
        decodedBytes = max(bitmapBytes, cgBytes.map { $0.overflow ? Int.max : $0.partialValue } ?? Int.max)
        let directory = directory
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            Self.ioQueue.sync { try? FileManager.default.removeItem(at: directory) }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        let directory = directory
        Self.ioQueue.async { try? FileManager.default.removeItem(at: directory) }
    }

    var residentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return residentImage == nil ? 0 : decodedBytes
    }

    @MainActor
    func spillToDisk() {
        lock.lock()
        guard !isSpilling, let image = residentImage else { lock.unlock(); return }
        isSpilling = true
        lock.unlock()
        guard let snapshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            lock.lock()
            isSpilling = false
            lock.unlock()
            return
        }
        Self.ioQueue.async { [self] in
            let saved = autoreleasepool { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("image.png")
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                        return false
                    }
                    CGImageDestinationAddImage(destination, snapshot, nil)
                    return CGImageDestinationFinalize(destination)
                } catch { return false }
            }
            lock.lock()
            // Keep the original on write failure; never silently lose a pin.
            if saved { residentImage = nil }
            isSpilling = false
            lock.unlock()
        }
    }

    /// Call on the I/O queue for restores. The public image accessor remains
    /// synchronous for compatibility, but does not cache decoded disk images.
    func loadImage() -> NSImage? {
        lock.lock()
        let image = residentImage
        lock.unlock()
        if let image { return image }
        let url = directory.appendingPathComponent("image.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: imageSize)
    }
}

// MARK: - Instant 0ms Hover Tooltip Buttons (Pure Black & White Monochrome Style)

public struct InstantBlackIconButton: View {
    public let icon: String
    public var isSelected: Bool = false
    public var isHighlightedGreen: Bool = false
    public var isDisabled: Bool = false
    public let tooltip: String
    public let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    public init(
        icon: String,
        isSelected: Bool = false,
        isHighlightedGreen: Bool = false,
        isDisabled: Bool = false,
        tooltip: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.isSelected = isSelected || isHighlightedGreen
        self.isHighlightedGreen = isHighlightedGreen
        self.isDisabled = isDisabled
        self.tooltip = tooltip
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            iconContent
                .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isDisabled ? 0.28 : (isSelected ? 1.0 : 0.88)))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isSelected
                                ? SnapLexTheme.toolbarSelection(for: colorScheme)
                                : (isHovered && !isDisabled ? SnapLexTheme.toolbarHover(for: colorScheme) : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .overlay(alignment: .top) {
            if isHovered && !tooltip.isEmpty {
                Text(L10n.string(tooltip))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SnapLexTheme.tooltipForeground(for: colorScheme))
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SnapLexTheme.tooltipBackground(for: colorScheme).opacity(0.97))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                            )
                    )
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
    }

    /// Supports `"wechat:text"` (`[T]`), `"wechat:translate"` (`A ↔ 文`), `"wechat:ocr"` (`⌜A⌟`),
    /// `"glyph:X"` (`B` / `I`), and standard SF Symbols.
    @ViewBuilder
    private var iconContent: some View {
        if icon == "wechat:text" {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: 1.35)
                    .frame(width: 15, height: 15)
                Text("T")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
            }
        } else if icon == "wechat:translate" {
            SnapLexTranslationIcon(size: 17)
        } else if icon == "wechat:ocr" {
            WeChatOCRIconView()
        } else if icon.hasPrefix("glyph:") {
            let glyph = String(icon.dropFirst(6))
            switch glyph {
            case "B":
                Text("B").font(.system(size: 14.5, weight: .heavy))
            case "I":
                Text("I").font(.system(size: 15, weight: .medium, design: .serif)).italic()
            default:
                Text(glyph).font(.system(size: 16, weight: .semibold, design: .serif))
            }
        } else {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
        }
    }
}

/// WeChat-style OCR Icon: 4 corner scanner brackets `⌜ ⌝ ⌞ ⌟` with `A` in the center
private struct WeChatOCRIconView: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let m: CGFloat = 1.2
                let arm: CGFloat = 4.2
                var path = Path()

                // Top-left bracket
                path.move(to: CGPoint(x: m, y: m + arm))
                path.addLine(to: CGPoint(x: m, y: m))
                path.addLine(to: CGPoint(x: m + arm, y: m))

                // Top-right bracket
                path.move(to: CGPoint(x: w - m - arm, y: m))
                path.addLine(to: CGPoint(x: w - m, y: m))
                path.addLine(to: CGPoint(x: w - m, y: m + arm))

                // Bottom-left bracket
                path.move(to: CGPoint(x: m, y: h - m - arm))
                path.addLine(to: CGPoint(x: m, y: h - m))
                path.addLine(to: CGPoint(x: m + arm, y: h - m))

                // Bottom-right bracket
                path.move(to: CGPoint(x: w - m - arm, y: h - m))
                path.addLine(to: CGPoint(x: w - m, y: h - m))
                path.addLine(to: CGPoint(x: w - m, y: h - m - arm))

                context.stroke(
                    path,
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(width: 16, height: 16)

            Text("A")
                .font(.system(size: 9.8, weight: .bold, design: .rounded))
        }
        .frame(width: 16, height: 16)
    }
}

public struct InstantBlackTextPillButton: View {
    public let label: String
    public var isSelected: Bool = false
    public let tooltip: String
    public let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    public init(
        label: String,
        isSelected: Bool = false,
        tooltip: String,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.isSelected = isSelected
        self.tooltip = tooltip
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isSelected ? 1 : 0.66))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isSelected
                                ? SnapLexTheme.toolbarSelection(for: colorScheme)
                                : (isHovered ? SnapLexTheme.toolbarHover(for: colorScheme) : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .overlay(alignment: .top) {
            if isHovered && !tooltip.isEmpty {
                Text(L10n.string(tooltip))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SnapLexTheme.tooltipForeground(for: colorScheme))
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SnapLexTheme.tooltipBackground(for: colorScheme).opacity(0.97))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                            )
                    )
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
    }
}

public struct InstantBlackStartRecordButton: View {
    public let tooltip: String
    public let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    public init(tooltip: String, action: @escaping () -> Void) {
        self.tooltip = tooltip
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(L10n.string("开始录制"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? SnapLexTheme.toolbarHover(for: colorScheme) : SnapLexTheme.toolbarBorder(for: colorScheme))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .overlay(alignment: .top) {
            if isHovered && !tooltip.isEmpty {
                Text(L10n.string(tooltip))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SnapLexTheme.tooltipForeground(for: colorScheme))
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SnapLexTheme.tooltipBackground(for: colorScheme).opacity(0.97))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                            )
                    )
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
    }
}

@MainActor
public final class PinManager: ObservableObject {
    public static let shared = PinManager()

    @Published public private(set) var activePins: [PinnedImageWindow] = []
    @Published public private(set) var closedHistory: [PinHistoryRecord] = []
    @Published public var allPinsHidden: Bool = false

    // Retain at most 64 MiB of decoded closed-pin images, with images over
    // 16 MiB and all but the two most recent records backed by private PNGs.
    private let closedImageByteBudget = 64 * 1_024 * 1_024
    private let closedImageIndividualLimit = 16 * 1_024 * 1_024

    private init() {}

    private func rememberClosedPin(_ window: PinnedImageWindow) {
        let record = PinHistoryRecord(image: window.originalImage, frame: window.frame, closedAt: Date())
        closedHistory = RecentHistoryPolicy.inserting(record, into: closedHistory, limit: 25)
        var remaining = closedImageByteBudget
        for (index, record) in closedHistory.enumerated() {
            let bytes = record.storage.residentBytes
            if index >= 2 || bytes > closedImageIndividualLimit || bytes > remaining {
                record.storage.spillToDisk()
            } else {
                remaining -= bytes
            }
        }
    }

    public func applyAppearance(_ appearance: NSAppearance?) {
        activePins.forEach { $0.applyAppearance(appearance) }
    }

    /// Pins a borderless NSImage with shadow ON by default and an outer floating hover toolbar!
    @discardableResult
    public func pinImage(
        _ image: NSImage,
        at screenRect: NSRect? = nil,
        startWithInPlaceTranslation: Bool = false,
        startWithOCRSidebar: Bool = false,
        startWithShadow: Bool = true
    ) -> PinnedImageWindow {
        let targetRect: NSRect

        if let screenRect = screenRect {
            targetRect = NSRect(
                x: screenRect.minX,
                y: screenRect.minY,
                width: max(80, screenRect.width),
                height: max(60, screenRect.height)
            )
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            let vFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let imgW = max(80, image.size.width)
            let imgH = max(60, image.size.height)
            let fitScale = min(1.0, min((vFrame.width * 0.78) / imgW, (vFrame.height * 0.78) / imgH))
            let w = round(max(80, imgW * fitScale))
            let h = round(max(60, imgH * fitScale))
            let x = round(max(vFrame.minX + 20, min(mouse.x - w / 2, vFrame.maxX - w - 20)))
            let y = round(max(vFrame.minY + 20, min(mouse.y - h / 2, vFrame.maxY - h - 20)))
            targetRect = NSRect(x: x, y: y, width: w, height: h)
        }

        let win = PinnedImageWindow(image: image, initialRect: targetRect, startWithShadow: startWithShadow)
        activePins.append(win)
        allPinsHidden = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if startWithInPlaceTranslation {
            win.activateInPlaceTranslation()
        }
        if startWithOCRSidebar {
            win.activateOCRSidebar()
        }
        return win
    }

    /// Decode the original screenshot away from the main thread instead of pinning its thumbnail.
    public func pinImageFile(_ url: URL) {
        Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }.value
            guard let image else { NSSound.beep(); return }
            pinImage(NSImage(cgImage: image, size: .zero))
        }
    }

    public func pinFromClipboard() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) {
            pinImage(img, at: nil)
            return
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let renderedImg = renderTextOrColorCardToImage(text: text)
            pinImage(renderedImg, at: nil)
        }
    }

    public func closePin(_ window: PinnedImageWindow) {
        guard activePins.contains(where: { $0 === window }) else { return }
        window.cleanupCompanionWindows()
        rememberClosedPin(window)
        window.orderOut(nil)
        activePins.removeAll { $0 === window }
    }

    public func restoreLastClosedPin() {
        guard !closedHistory.isEmpty else { return }
        let record = closedHistory.removeFirst()
        // Decode and publish in one FIFO, so repeated restore shortcuts cannot
        // reorder windows when a large image takes longer to decode.
        ClosedPinImage.ioQueue.async { [recordStorage = record.storage, recordFrame = record.frame] in
            let image = recordStorage.loadImage()
            DispatchQueue.main.async { [self] in
                guard let image else { NSSound.beep(); return }
                let window = pinImage(image, at: recordFrame)
                // pinImage applies minimum dimensions; restores preserve even
                // a closed thumbnail's exact frame.
                window.setFrame(recordFrame, display: true)
            }
        }
    }

    public func toggleHideAllPins() {
        allPinsHidden.toggle()
        for pin in activePins {
            if allPinsHidden {
                pin.orderOut(nil)
                pin.hideCompanionWindows()
            } else {
                pin.orderFrontRegardless()
                pin.syncCompanionWindows()
            }
        }
    }

    public func unlockAllClickThroughPins() {
        for pin in activePins {
            pin.setClickThrough(false)
        }
    }

    public func closeAllPins() {
        for pin in activePins {
            pin.cleanupCompanionWindows()
            rememberClosedPin(pin)
            pin.orderOut(nil)
        }
        activePins.removeAll()
    }

    private func renderTextOrColorCardToImage(text: String) -> NSImage {
        if let hexColor = parseHexColor(text) {
            let size = NSSize(width: 240, height: 120)
            let img = NSImage(size: size)
            img.lockFocus()
            hexColor.setFill()
            NSRect(origin: .zero, size: size).fill()

            let labelBg = NSRect(x: 0, y: 0, width: size.width, height: 34)
            NSColor.black.withAlphaComponent(0.68).setFill()
            labelBg.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            (text.uppercased() as NSString).draw(at: NSPoint(x: 12, y: 8), withAttributes: attrs)
            img.unlockFocus()
            return img
        }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1.0),
            .paragraphStyle: paragraph
        ]

        let maxWidth: CGFloat = 520
        let clippedText = String(text.prefix(1500))
        let bound = (clippedText as NSString).boundingRect(
            with: NSSize(width: maxWidth - 32, height: 900),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let cardW = max(240, min(maxWidth, ceil(bound.width) + 36))
        let cardH = max(90, min(700, ceil(bound.height) + 36))
        let size = NSSize(width: cardW, height: cardH)

        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.98).setFill()
        NSRect(origin: .zero, size: size).fill()
        (clippedText as NSString).draw(
            in: NSRect(x: 18, y: 18, width: cardW - 36, height: cardH - 36),
            withAttributes: attrs
        )
        img.unlockFocus()
        return img
    }

    private func parseHexColor(_ str: String) -> NSColor? {
        let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("#") && (cleaned.count == 7 || cleaned.count == 4) else { return nil }
        var hex = String(cleaned.dropFirst())
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let val = Int(hex, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Borderless PinnedImageWindow (Default Shadow ON + Outer Companion Toolbar Panel)

@MainActor
public final class PinnedImageWindow: NSPanel, NSWindowDelegate {
    public private(set) var originalImage: NSImage
    private var baseAspectSize: NSSize
    private let sidebarWidth: CGFloat = 290

    fileprivate let viewModel: PinnedWindowViewModel
    private var preMinimizeFrame: NSRect = .zero

    /// Outer Floating Black Toolbar Panel positioned OUTSIDE the pinned image!
    private var outerToolbarPanel: NSPanel?
    private var outerToolbarFittingSize: NSSize?
    /// Companion floating badge window so Mouse Click-Through mode can ALWAYS be cancelled with 1 click!
    private var unlockClickThroughPanel: NSPanel?
    private var hideToolbarTask: Task<Void, Never>?
    private var imageEffectTask: Task<Void, Never>?
    private var isApplyingZoom: Bool = false

    public init(image: NSImage, initialRect: NSRect, startWithShadow: Bool = true) {
        self.originalImage = image
        self.baseAspectSize = NSRect(origin: .zero, size: image.size).size
        self.viewModel = PinnedWindowViewModel(originalImage: image)

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        self.isOpaque = false
        self.hasShadow = startWithShadow
        self.viewModel.hasWindowShadow = startWithShadow
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.delegate = self

        let rootView = PinnedImageRootView(
            vm: viewModel,
            onImageHoverChanged: { [weak self] hovering in
                self?.handleImageHoverChanged(hovering)
            },
            onToggleInPlaceTranslation: { [weak self] in self?.toggleInPlaceTranslation() },
            onToggleOCRSidebar: { [weak self] in self?.toggleOCRSidebar() },
            onToggleAnnotationMode: { [weak self] in self?.toggleAnnotationMode() },
            onToggleShadow: { [weak self] in self?.toggleWindowShadow() },
            onToggleClickThrough: { [weak self] in
                guard let self = self else { return }
                self.setClickThrough(!self.viewModel.isClickThrough)
            },
            onToggleThumbnail: { [weak self] in self?.toggleThumbnailMode() },
            onRotate90: { [weak self] in self?.rotate90Clockwise() },
            onFlipHorizontal: { [weak self] in self?.flipHorizontally() },
            onCopyImage: { [weak self] in self?.copyImageToClipboard() },
            onSaveImage: { [weak self] in self?.saveImageToDisk() },
            onClose: { [weak self] in
                guard let self = self else { return }
                PinManager.shared.closePin(self)
            }
        )

        let hosting = PinInteractiveHostingView(rootView: rootView)
        hosting.ownerPinWindow = self
        self.contentView = hosting

        setupOuterToolbarPanel()
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    fileprivate func applyAppearance(_ appearance: NSAppearance?) {
        self.appearance = appearance
        outerToolbarPanel?.appearance = appearance
        outerToolbarFittingSize = nil
        unlockClickThroughPanel?.appearance = appearance
    }

    public func windowDidMove(_ notification: Notification) {
        syncCompanionWindows()
    }

    public func windowDidResize(_ notification: Notification) {
        syncCompanionWindows()
    }

    // MARK: - Outer Toolbar Panel (Positioned OUTSIDE the Pinned Image, with Hover Support!)

    private func setupOuterToolbarPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let toolbarView = PinOuterToolbarSwiftUIView(
            vm: viewModel,
            onToolbarHoverChanged: { [weak self] hovering in
                self?.handleToolbarHoverChanged(hovering)
            },
            onSubbarLayoutChanged: { [weak self] in
                DispatchQueue.main.async {
                    self?.outerToolbarFittingSize = nil
                    self?.showAndPositionOuterToolbar()
                }
            },
            onZoomIn: { [weak self] in self?.stepZoom(by: 0.15) },
            onZoomOut: { [weak self] in self?.stepZoom(by: -0.15) },
            onResetActualSize: { [weak self] in self?.resetToActualSize() },
            onRotate90: { [weak self] in self?.rotate90Clockwise() },
            onApplyImageEffect: { [weak self] effect in self?.applyImageEffect(effect) },
            onToggleAnnotationMode: { [weak self] in self?.toggleAnnotationMode() },
            onToggleInPlaceTranslation: { [weak self] in self?.toggleInPlaceTranslation() },
            onToggleOCRSidebar: { [weak self] in self?.toggleOCRSidebar() },
            onToggleShadow: { [weak self] in self?.toggleWindowShadow() },
            onToggleClickThrough: { [weak self] in
                guard let self = self else { return }
                self.setClickThrough(!self.viewModel.isClickThrough)
            },
            onCopyImage: { [weak self] in self?.copyImageToClipboard() },
            onSaveImage: { [weak self] in self?.saveImageToDisk() },
            onClose: { [weak self] in
                guard let self = self else { return }
                PinManager.shared.closePin(self)
            }
        )

        let hosting = NSHostingView(rootView: toolbarView)
        panel.contentView = hosting
        self.outerToolbarPanel = panel
    }

    private func handleImageHoverChanged(_ hovering: Bool) {
        viewModel.isHoveringImage = hovering
        evaluateOuterToolbarVisibility()
    }

    private func handleToolbarHoverChanged(_ hovering: Bool) {
        viewModel.isHoveringToolbar = hovering
        evaluateOuterToolbarVisibility()
    }

    private func evaluateOuterToolbarVisibility() {
        hideToolbarTask?.cancel()
        if viewModel.isMinimized || viewModel.isClickThrough {
            hideOuterToolbar()
            return
        }
        if viewModel.isHoveringImage || viewModel.isHoveringToolbar || viewModel.isAnnotating {
            showAndPositionOuterToolbar()
        } else {
            // 240ms grace delay so moving cursor across the 6pt gap between image and outer toolbar never flickers!
            hideToolbarTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                if !self.viewModel.isHoveringImage && !self.viewModel.isHoveringToolbar && !self.viewModel.isAnnotating {
                    self.hideOuterToolbar()
                }
            }
        }
    }

    private func showAndPositionOuterToolbar(forceReposition: Bool = false) {
        guard let panel = outerToolbarPanel, let hosting = panel.contentView else { return }
        let fit: NSSize
        if let cachedSize = outerToolbarFittingSize, !forceReposition {
            fit = cachedSize
        } else {
            hosting.invalidateIntrinsicContentSize()
            hosting.layoutSubtreeIfNeeded()
            fit = hosting.fittingSize
            outerToolbarFittingSize = fit
        }
        let barW = max(440, fit.width)
        let barH = max(68, fit.height)

        // If the outer toolbar is already visible and the user is hovering on it or zooming,
        // keep its exact horizontal/vertical anchor so the `+` / `-` buttons NEVER jump under the cursor!
        if panel.isVisible && (viewModel.isHoveringToolbar || isApplyingZoom) && !forceReposition {
            panel.setFrame(NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y, width: barW, height: barH), display: true)
            panel.orderFrontRegardless()
            return
        }

        let anchorFrame = toolbarAnchorFrame
        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, anchorFrame) }) ?? NSScreen.main
        let vFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchorFrame.midX - barW / 2
        x = max(vFrame.minX + 8, min(x, vFrame.maxX - barW - 8))

        // Align the toolbar to the primary pinned image area, excluding the optional OCR side drawer.
        // Place it below the image by default and above it when there is not enough room below.
        var y = anchorFrame.minY - barH - 4
        if y < vFrame.minY + 8 {
            y = anchorFrame.maxY + 4
        }

        panel.setFrame(NSRect(x: x, y: y, width: barW, height: barH), display: true)
        panel.orderFrontRegardless()
    }

    private var toolbarAnchorFrame: NSRect {
        let drawerWidth = viewModel.showOCRSidebar ? sidebarWidth : 0
        return NSRect(
            x: frame.minX,
            y: frame.minY,
            width: max(80, frame.width - drawerWidth),
            height: frame.height
        )
    }

    private func hideOuterToolbar() {
        guard let panel = outerToolbarPanel else { return }
        if panel.parent != nil {
            self.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    public func toggleAnnotationMode() {
        viewModel.isAnnotating.toggle()
        if !viewModel.isAnnotating {
            viewModel.activeTool = .selectMove
            viewModel.commitInlineTextIfNeeded()
        } else {
            viewModel.activeTool = .selectMove
        }
        self.isMovableByWindowBackground = !viewModel.isAnnotating
        DispatchQueue.main.async {
            self.showAndPositionOuterToolbar(forceReposition: true)
        }
    }

    public func toggleWindowShadow() {
        viewModel.hasWindowShadow.toggle()
        self.hasShadow = viewModel.hasWindowShadow
        self.invalidateShadow()
        viewModel.showHUD(L10n.string(viewModel.hasWindowShadow ? "已开启窗口阴影" : "已取消窗口阴影"))
    }

    public func cleanupCompanionWindows() {
        viewModel.close()
        imageEffectTask?.cancel()
        imageEffectTask = nil
        hideToolbarTask?.cancel()
        hideToolbarTask = nil
        if let bar = outerToolbarPanel {
            if bar.parent != nil { removeChildWindow(bar) }
            bar.orderOut(nil)
        }
        outerToolbarPanel = nil

        if let pill = unlockClickThroughPanel {
            if pill.parent != nil { removeChildWindow(pill) }
            pill.orderOut(nil)
        }
        unlockClickThroughPanel = nil
    }

    public func hideCompanionWindows() {
        hideOuterToolbar()
        unlockClickThroughPanel?.orderOut(nil)
    }

    public func syncCompanionWindows() {
        if !isApplyingZoom, !viewModel.isHoveringToolbar, let bar = outerToolbarPanel, bar.isVisible {
            showAndPositionOuterToolbar()
        }
        guard viewModel.isClickThrough, let pill = unlockClickThroughPanel else { return }
        let pillW: CGFloat = 116
        let pillH: CGFloat = 28
        let origin = NSPoint(
            x: frame.maxX - pillW - 6,
            y: frame.maxY - pillH - 6
        )
        pill.setFrameOrigin(origin)
        pill.orderFrontRegardless()
    }

    // MARK: - Image 2 Mode: In-Place Image Translation (`[文A]`)

    public func activateInPlaceTranslation() {
        if !viewModel.isInPlaceTranslated {
            toggleInPlaceTranslation()
        }
    }

    public func toggleInPlaceTranslation() {
        guard !viewModel.isClosed else { return }
        if viewModel.isInPlaceTranslated {
            viewModel.cancelInPlaceTranslation()
            viewModel.rebuildDisplayedImage()
            viewModel.showHUD(L10n.string("已还原原图"))
            return
        }

        viewModel.isInPlaceTranslated = true
        if let cached = viewModel.cachedInPlaceResult {
            viewModel.ocrBlocks = cached.blocks
            if viewModel.ocrSidebarText.isEmpty {
                viewModel.ocrSidebarText = cached.fullOriginalText
            }
            viewModel.rebuildDisplayedImage()
            viewModel.showHUD(L10n.string("已原位贴合翻译"))
            return
        }

        viewModel.isTranslatingInPlace = true
        viewModel.showHUD(L10n.string("正在原位识别并贴合翻译..."))
        let vm = viewModel
        let srcImg = vm.originalImage
        let requestID = UUID()
        let generation = vm.ocrGeneration
        let recognition = vm.sharedRecognition()
        vm.pendingTranslationID = requestID
        vm.inPlaceTask = Task { @MainActor [weak vm] in
            let blocks = await recognition.value
            guard !Task.isCancelled, let vm,
                  vm.pendingTranslationID == requestID,
                  vm.acceptRecognition(blocks, generation: generation) else { return }
            guard !blocks.isEmpty else {
                vm.isTranslatingInPlace = false
                vm.isInPlaceTranslated = false
                vm.showHUD(L10n.string("未识别到文本"))
                return
            }

            vm.pendingTranslationBlocks = blocks
            vm.pendingTranslationImage = srcImg
            if vm.ocrSidebarText.isEmpty {
                vm.ocrSidebarText = blocks.map(\.originalText).joined(separator: "\n")
            }
            let text = blocks.map(\.originalText).joined(separator: "\n")
            let targetCode = NativeTranslationSupport.preferredTargetCode(for: text)
            let sourceCodes = NativeTranslationSupport.distinctSourceLanguageCodes(
                in: blocks.map(\.originalText),
                excluding: targetCode
            )
            vm.pendingTranslationSourceCodes = Array(sourceCodes.dropFirst())
            vm.pendingTranslationTargetCode = targetCode
            guard let sourceCode = sourceCodes.first else {
                vm.isTranslatingInPlace = false
                vm.isInPlaceTranslated = false
                vm.showHUD(L10n.string("识别到的文字已是目标语言"))
                return
            }
            vm.pendingTranslationSourceCode = sourceCode

            if AppSettings.shared.translationEngine == .google {
                vm.translationConfiguration = nil
                let targetLabel = AppSettings.targetLanguages.first(where: { $0.code == targetCode })?.label ?? "简体中文"
                do {
                        let indicesToTranslate = blocks.indices.filter {
                            NativeTranslationSupport.sourceLanguageCode(for: blocks[$0].originalText) != targetCode
                        }
                        let translated = try await GoogleTranslationService.shared.translate(
                            texts: indicesToTranslate.map { blocks[$0].originalText },
                            targetLanguage: targetLabel
                        )
                        guard vm.pendingTranslationID == requestID else { return }
                        var translatedBlocks = blocks
                        for (translationIndex, blockIndex) in indicesToTranslate.enumerated() {
                            translatedBlocks[blockIndex].translatedText = translated.indices.contains(translationIndex)
                                ? translated[translationIndex]
                                : translatedBlocks[blockIndex].originalText
                        }
                        vm.completeInPlaceTranslation(
                            translatedBlocks,
                            sourceImage: srcImg,
                            requestID: requestID
                        )
                } catch {
                        guard !Task.isCancelled, vm.pendingTranslationID == requestID else { return }
                        // Reuse the pending OCR blocks and the native multi-language
                        // pipeline when Google is unavailable or rate limited.
                        vm.translationConfiguration = NativeTranslationSupport.makeConfiguration(
                            source: sourceCode,
                            target: targetCode
                        )
                }
                return
            }

            let source = Locale.Language(identifier: sourceCode)
            let target = Locale.Language(identifier: targetCode)
            if var configuration = vm.translationConfiguration,
               configuration.source == source,
               configuration.target == target {
                configuration.invalidate()
                vm.translationConfiguration = configuration
            } else {
                vm.translationConfiguration = NativeTranslationSupport.makeConfiguration(
                    source: sourceCode,
                    target: targetCode
                )
            }
        }
    }

    // MARK: - Image 1 Mode: Right-Side OCR Text Drawer (`[文]`)

    public func activateOCRSidebar() {
        if !viewModel.showOCRSidebar {
            toggleOCRSidebar()
        }
    }

    public func toggleOCRSidebar() {
        guard !viewModel.isClosed else { return }
        viewModel.showOCRSidebar.toggle()

        var f = frame
        if viewModel.showOCRSidebar {
            f.size.width += sidebarWidth
        } else {
            f.size.width = max(120, f.size.width - sidebarWidth)
        }
        setFrame(f, display: true, animate: true)
        syncCompanionWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.outerToolbarPanel?.isVisible == true else { return }
            self.showAndPositionOuterToolbar(forceReposition: true)
        }

        if viewModel.showOCRSidebar {
            viewModel.startSidebarRecognitionIfNeeded()
        } else {
            viewModel.sidebarTask?.cancel()
            viewModel.sidebarTask = nil
            viewModel.isExtractingOCR = false
            viewModel.cancelUnusedRecognition()
        }
    }

    // MARK: - Zoom / Opacity / Rotate / Flip / Thumbnail

    public func stepZoom(by delta: CGFloat) {
        applyScale(viewModel.scale + delta)
    }

    public func resetToActualSize() {
        applyScale(1.0)
        viewModel.opacity = 1.0
        self.alphaValue = 1.0
    }

    public func handleScrollWheel(_ event: NSEvent) {
        guard !viewModel.isMinimized else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.05 else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) {
            let step: CGFloat = delta > 0 ? 0.05 : -0.05
            viewModel.opacity = max(0.15, min(1.0, viewModel.opacity + step))
            self.alphaValue = viewModel.opacity
            viewModel.showHUD(L10n.format("透明度 %d%%", Int(round(viewModel.opacity * 100))))
        } else {
            let factor: CGFloat = delta > 0 ? 1.06 : 0.94
            applyScale(viewModel.scale * factor)
        }
    }

    private func applyScale(_ newScale: CGFloat) {
        let clamped = max(0.15, min(4.0, newScale))
        viewModel.scale = clamped

        let isRotatedSideways = (viewModel.rotationDegrees % 180 != 0)
        let refW = isRotatedSideways ? baseAspectSize.height : baseAspectSize.width
        let refH = isRotatedSideways ? baseAspectSize.width : baseAspectSize.height

        let extraSidebar = viewModel.showOCRSidebar ? sidebarWidth : 0
        let newW = max(90, round(refW * clamped) + extraSidebar)
        let newH = max(60, round(refH * clamped))

        let newOriginX = round(frame.midX - newW / 2)
        let newOriginY: CGFloat

        // Anchor the edge of the pinned image facing `outerToolbarPanel` so the toolbar
        // NEVER moves or gets overlapped during continuous zooming!
        if let bar = outerToolbarPanel, bar.isVisible {
            if bar.frame.midY <= frame.midY {
                // Toolbar is below the pinned image -> keep bottom edge (`minY`) fixed!
                newOriginY = frame.minY
            } else {
                // Toolbar is above the pinned image -> keep top edge (`maxY`) fixed!
                newOriginY = round(frame.maxY - newH)
            }
        } else {
            newOriginY = round(frame.midY - newH / 2)
        }

        let newFrame = NSRect(
            x: newOriginX,
            y: newOriginY,
            width: newW,
            height: newH
        )
        isApplyingZoom = true
        setFrame(newFrame, display: true)
        isApplyingZoom = false
        syncCompanionWindows()
        viewModel.showHUD(L10n.format("缩放 %d%%", Int(round(clamped * 100))))
    }

    public func toggleThumbnailMode() {
        guard !viewModel.isAnnotating else { return }
        viewModel.isMinimized.toggle()
        if viewModel.isMinimized {
            hideOuterToolbar()
            preMinimizeFrame = frame
            let thumbSize: CGFloat = 54
            let newOrigin = NSPoint(x: frame.midX - thumbSize / 2, y: frame.midY - thumbSize / 2)
            setFrame(NSRect(origin: newOrigin, size: NSSize(width: thumbSize, height: thumbSize)), display: true, animate: true)
        } else {
            setFrame(preMinimizeFrame, display: true, animate: true)
        }
        syncCompanionWindows()
    }

    public func rotate90Clockwise() {
        guard !viewModel.isMinimized else { return }
        viewModel.rotationDegrees = (viewModel.rotationDegrees + 90) % 360
        viewModel.rebuildDisplayedImage()
        applyScale(viewModel.scale)
    }

    private func applyImageEffect(_ effect: VisionImageEffect) {
        guard !viewModel.isMinimized, imageEffectTask == nil else { return }
        viewModel.commitInlineTextIfNeeded()
        viewModel.showHUD(effect.progressMessage)
        let sourceImage = viewModel.originalImage

        imageEffectTask = Task { @MainActor [weak self] in
            do {
                let processed = try await VisionImageEffectsService.shared.apply(effect, to: sourceImage)
                guard !Task.isCancelled, let self, !self.viewModel.isClosed else { return }
                defer { self.imageEffectTask = nil }
                self.viewModel.invalidateOCRSource()
                self.originalImage = processed
                self.viewModel.originalImage = processed
                self.viewModel.startSidebarRecognitionIfNeeded()
                if effect == .extractSubject {
                    self.viewModel.hasWindowShadow = false
                    self.hasShadow = false
                    self.invalidateShadow()
                }
                self.viewModel.rebuildDisplayedImage()
                self.viewModel.showHUD(effect.completionMessage)
            } catch {
                guard !Task.isCancelled, let self, !self.viewModel.isClosed else { return }
                self.imageEffectTask = nil
                self.viewModel.showHUD(
                    (error as? VisionImageEffectsError)?.errorDescription ?? L10n.string("无法生成图片效果。")
                )
            }
        }
    }

    public func flipHorizontally() {
        guard !viewModel.isMinimized else { return }
        viewModel.isFlippedHorizontally.toggle()
        viewModel.rebuildDisplayedImage()
        viewModel.showHUD(L10n.string(viewModel.isFlippedHorizontally ? "已水平翻转" : "已恢复镜像"))
    }

    // MARK: - Mouse Click-Through with Always-Clickable Unlock Companion Pill!

    public func setClickThrough(_ enabled: Bool) {
        viewModel.isClickThrough = enabled
        self.ignoresMouseEvents = enabled
        if enabled {
            hideOuterToolbar()
            if viewModel.opacity > 0.85 {
                viewModel.opacity = 0.78
                self.alphaValue = 0.78
            }
            showUnlockClickThroughPill()
            viewModel.showHUD(L10n.string("已开启鼠标穿透 (点击右上角「退出穿透」可立即恢复)"))
        } else {
            if let pill = unlockClickThroughPanel {
                removeChildWindow(pill)
                pill.orderOut(nil)
            }
            viewModel.opacity = 1.0
            self.alphaValue = 1.0
            viewModel.showHUD(L10n.string("已解除鼠标穿透"))
        }
    }

    private func showUnlockClickThroughPill() {
        if unlockClickThroughPanel == nil {
            let pillW: CGFloat = 116
            let pillH: CGFloat = 28
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: pillW, height: pillH),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let btnView = Button(action: { [weak self] in
                self?.setClickThrough(false)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(L10n.string("退出穿透"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color(white: 0.10, opacity: 0.96))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            panel.contentView = NSHostingView(rootView: btnView)
            unlockClickThroughPanel = panel
        }
        syncCompanionWindows()
        if let pill = unlockClickThroughPanel, pill.parent == nil {
            self.addChildWindow(pill, ordered: .above)
        }
    }

    public func copyImageToClipboard() {
        viewModel.commitInlineTextIfNeeded()
        let img = viewModel.renderFlattenedImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        viewModel.showHUD(L10n.string("已复制图像"))
    }

    public func saveImageToDisk() {
        viewModel.commitInlineTextIfNeeded()
        let img = viewModel.renderFlattenedImage()
        guard let imageSnapshot = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "SnapLex_Pin_\(formatter.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url {
            Task { [weak self] in
                let saved = await PNGImageWriter.write(imageSnapshot, to: url)
                guard let self else { return }
                self.viewModel.showHUD(L10n.string(saved ? "已保存 PNG" : "保存 PNG 失败"))
            }
        }
    }

    override public func keyDown(with event: NSEvent) {
        if EscapeKeyPolicy.isEscapeKeyCode(event.keyCode) {
            PinManager.shared.closePin(self)
            return
        }
        if viewModel.isEditingInlineText {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51: // Delete -> Close pin
            PinManager.shared.closePin(self)
        case 6 where flags.contains([.command, .shift]): // Cmd+Shift+Z -> Redo
            viewModel.redoAnnotation()
        case 6 where flags.contains(.command): // Cmd+Z -> Undo
            viewModel.undoAnnotation()
        case 15: // 'R' -> Rotate 90°
            rotate90Clockwise()
        case 4: // 'H' -> Flip Horizontally
            flipHorizontally()
        case 17: // 'T' -> Toggle In-Place Image Translation (`[文A]`)
            toggleInPlaceTranslation()
        case 29: // '0' -> Reset 100%
            resetToActualSize()
        case 8 where flags.contains(.command): // Cmd+C -> Copy image
            copyImageToClipboard()
        case 1 where flags.contains(.command): // Cmd+S -> Save image
            saveImageToDisk()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class PinInteractiveHostingView<Content: View>: NSHostingView<Content> {
    weak var ownerPinWindow: PinnedImageWindow?

    override func scrollWheel(with event: NSEvent) {
        ownerPinWindow?.handleScrollWheel(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, ownerPinWindow?.viewModel.isAnnotating == false {
            ownerPinWindow?.toggleThumbnailMode()
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - ViewModel for Pinned Image Window

@MainActor
fileprivate final class PinnedWindowViewModel: ObservableObject {
    var originalImage: NSImage
    @Published var displayedImage: NSImage
    @Published var scale: CGFloat = 1.0
    @Published var opacity: CGFloat = 1.0
    @Published var rotationDegrees: Int = 0
    @Published var isFlippedHorizontally: Bool = false

    @Published var isHoveringImage: Bool = false
    @Published var isHoveringToolbar: Bool = false
    @Published var isMinimized: Bool = false
    @Published var isClickThrough: Bool = false
    // Default shadow is ON!
    @Published var hasWindowShadow: Bool = true

    // Live Annotation State directly on Pinned Image!
    @Published var isAnnotating: Bool = false
    @Published var activeTool: SnipAnnotationTool = .selectMove
    @Published var strokeColor: NSColor = .systemRed
    @Published var strokeWidth: CGFloat = 3.5
    @Published var annotations: [SnipAnnotationItem] = []
    @Published var redoStack: [SnipAnnotationItem] = []
    @Published var currentDraftAnnotation: SnipAnnotationItem?
    @Published var selectedAnnotationID: UUID?
    var nextCounterNumber: Int = 1

    // Inline Direct Text Entry (NO popup dialog!)
    @Published var isEditingInlineText: Bool = false
    @Published var inlineTextOrigin: CGPoint = .zero
    @Published var inlineTextValue: String = ""
    // Text tool (A) style: no background, bold / italic / font size
    @Published var textFontSize: CGFloat = SnipTextStyle.defaultFontSize
    @Published var textBold: Bool = false
    @Published var textItalic: Bool = false
    var currentTextFont: NSFont {
        SnipTextStyle.font(size: textFontSize, bold: textBold, italic: textItalic)
    }
    /// Size of the annotation canvas (points) — used to flatten annotations into the exported image
    var canvasSize: CGSize = .zero

    // Image 2: In-Place Translation (`[文A]`)
    @Published var isInPlaceTranslated: Bool = false
    @Published var isTranslatingInPlace: Bool = false
    var cachedInPlaceResult: InPlaceOCRResult?
    @Published var translationConfiguration: TranslationSession.Configuration?
    var pendingTranslationBlocks: [OCRTextBlock] = []
    var pendingTranslationImage: NSImage?
    var pendingTranslationID: UUID?
    var pendingTranslationSourceCode: String = "en"
    var pendingTranslationSourceCodes: [String] = []
    var pendingTranslationTargetCode: String = "zh"

    // Image 1: Right-Side OCR Text Drawer (`[文]`)
    @Published var showOCRSidebar: Bool = false
    @Published var isExtractingOCR: Bool = false
    @Published var ocrSidebarText: String = ""
    @Published var showTranslatedInSidebar: Bool = false
    var ocrBlocks: [OCRTextBlock] = []
    private(set) var isClosed = false
    private(set) var ocrGeneration = UUID()
    private var recognizedBlocks: [OCRTextBlock]?
    private var recognitionTask: Task<[OCRTextBlock], Never>?
    var sidebarTask: Task<Void, Never>?
    var inPlaceTask: Task<Void, Never>?

    /// Both consumers recognize the untransformed source. Rendering applies
    /// rotation/mirroring afterwards, including to a translated image.
    func sharedRecognition() -> Task<[OCRTextBlock], Never> {
        if let recognizedBlocks { return Task { recognizedBlocks } }
        if let recognitionTask { return recognitionTask }
        let image = originalImage
        let task = Task { @MainActor in
            await InPlaceOCRService.shared.recognizeBlocks(in: image)
        }
        recognitionTask = task
        return task
    }

    func acceptRecognition(_ blocks: [OCRTextBlock], generation: UUID) -> Bool {
        guard !isClosed, ocrGeneration == generation else { return false }
        recognizedBlocks = blocks
        recognitionTask = nil
        return true
    }

    func startSidebarRecognitionIfNeeded() {
        guard !isClosed, showOCRSidebar, ocrSidebarText.isEmpty, sidebarTask == nil else { return }
        isExtractingOCR = true
        let generation = ocrGeneration
        let recognition = sharedRecognition()
        sidebarTask = Task { @MainActor [weak self] in
            let blocks = await recognition.value
            guard !Task.isCancelled, let self, self.showOCRSidebar,
                  self.acceptRecognition(blocks, generation: generation) else { return }
            self.sidebarTask = nil
            if self.cachedInPlaceResult == nil { self.ocrBlocks = blocks }
            // Translation or an edit may have supplied text while OCR ran.
            if self.ocrSidebarText.isEmpty {
                let fullText = blocks.map(\.originalText).joined(separator: "\n")
                self.ocrSidebarText = fullText.isEmpty ? L10n.string("（未在图中识别到文本）") : fullText
            }
            self.isExtractingOCR = false
        }
    }

    func cancelInPlaceTranslation() {
        pendingTranslationID = nil
        translationConfiguration = nil
        inPlaceTask?.cancel()
        inPlaceTask = nil
        pendingTranslationBlocks = []
        pendingTranslationImage = nil
        pendingTranslationSourceCodes = []
        isTranslatingInPlace = false
        isInPlaceTranslated = false
        cancelUnusedRecognition()
    }

    func cancelUnusedRecognition() {
        guard !showOCRSidebar, !isInPlaceTranslated else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        ocrGeneration = UUID()
    }

    func invalidateOCRSource() {
        cancelInPlaceTranslation()
        sidebarTask?.cancel()
        sidebarTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        ocrGeneration = UUID()
        recognizedBlocks = nil
        cachedInPlaceResult = nil
        ocrBlocks = []
        ocrSidebarText = ""
        showTranslatedInSidebar = false
        isExtractingOCR = false
    }

    func close() {
        isClosed = true
        invalidateOCRSource()
        hudTask?.cancel()
        hudTask = nil
    }

    @Published var hudMessage: String? = nil
    private var hudTask: Task<Void, Never>?

    init(originalImage: NSImage) {
        self.originalImage = originalImage
        self.displayedImage = originalImage
    }

    func completeInPlaceTranslation(
        _ blocks: [OCRTextBlock],
        sourceImage: NSImage,
        requestID: UUID?
    ) {
        guard !isClosed, !Task.isCancelled, let requestID, pendingTranslationID == requestID else { return }
        let originalText = blocks.map(\.originalText).joined(separator: "\n")
        let translatedText = blocks.map(\.translatedText).joined(separator: "\n")
        recordCompletedScreenshotTranslation(blocks: blocks)
        let renderedImage = InPlaceOCRService.renderTranslatedBlocksOnImage(baseImage: sourceImage, blocks: blocks)
        cachedInPlaceResult = InPlaceOCRResult(
            blocks: blocks,
            fullOriginalText: originalText,
            fullTranslatedText: translatedText,
            renderedTranslatedImage: renderedImage
        )
        ocrBlocks = blocks
        isTranslatingInPlace = false
        rebuildDisplayedImage()
        showHUD(L10n.string("✓ 原位翻译完成"))
    }

    func recordCompletedScreenshotTranslation(blocks: [OCRTextBlock]) {
        let source = AppSettings.targetLanguages.first(where: {
            NativeTranslationSupport.languageCode(for: $0.label) == pendingTranslationSourceCode
        })?.label ?? pendingTranslationSourceCode
        let target = AppSettings.targetLanguages.first(where: {
            NativeTranslationSupport.languageCode(for: $0.label) == pendingTranslationTargetCode
        })?.label ?? pendingTranslationTargetCode
        TranslationHistoryStore.shared.recordCompletedTranslation(
            inputText: blocks.map(\.originalText).joined(separator: "\n"),
            translatedText: blocks.map(\.translatedText).joined(separator: "\n"),
            sourceLanguage: source,
            targetLanguage: target,
            sourceApp: "截图翻译",
            trigger: .screenshot
        )
    }

    func commitInlineTextIfNeeded() {
        guard isEditingInlineText else { return }
        let trimmed = inlineTextValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let item = SnipAnnotationItem(
                tool: .text,
                startPoint: inlineTextOrigin,
                endPoint: inlineTextOrigin,
                color: strokeColor,
                lineWidth: strokeWidth,
                text: trimmed,
                fontSize: textFontSize,
                isBold: textBold,
                isItalic: textItalic
            )
            annotations.append(item)
            redoStack.removeAll()
        }
        inlineTextValue = ""
        isEditingInlineText = false
    }

    func undoAnnotation() {
        commitInlineTextIfNeeded()
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    func redoAnnotation() {
        commitInlineTextIfNeeded()
        guard let item = redoStack.popLast() else { return }
        annotations.append(item)
    }

    func rebuildDisplayedImage() {
        let base: NSImage
        if isInPlaceTranslated, let cached = cachedInPlaceResult {
            base = cached.renderedTranslatedImage
        } else {
            base = originalImage
        }
        displayedImage = Self.transformImage(
            base,
            rotationDegrees: rotationDegrees,
            flipHorizontally: isFlippedHorizontally
        )
    }

    func renderFlattenedImage() -> NSImage {
        guard !annotations.isEmpty, canvasSize.width > 1, canvasSize.height > 1 else { return displayedImage }
        let base = displayedImage
        let items = annotations
        let canvas = canvasSize
        let pixelW = base.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CGFloat($0.width) } ?? base.size.width * 2

        let content = ZStack {
            Image(nsImage: base)
                .resizable()
                .interpolation(.high)
                .frame(width: canvas.width, height: canvas.height)
            Canvas { context, _ in
                for item in items {
                    PinnedImageRootView.drawSwiftUIAnnotation(item, in: &context)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
        .frame(width: canvas.width, height: canvas.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = max(1, pixelW / canvas.width)
        guard let cg = renderer.cgImage else { return base }
        return NSImage(cgImage: cg, size: base.size)
    }

    func showHUD(_ text: String) {
        hudMessage = text
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if !Task.isCancelled {
                hudMessage = nil
            }
        }
    }

    private static func transformImage(_ src: NSImage, rotationDegrees: Int, flipHorizontally: Bool) -> NSImage {
        PixelPreservingImageRenderer.transform(src, rotationDegrees: rotationDegrees, flipHorizontally: flipHorizontally)
    }
}

// MARK: - Outer Floating Black Toolbar View (Rendered in Companion Window OUTSIDE the Image!)

private struct PinOuterToolbarSwiftUIView: View {
    @ObservedObject var vm: PinnedWindowViewModel
    @Environment(\.colorScheme) private var colorScheme
    let onToolbarHoverChanged: (Bool) -> Void
    let onSubbarLayoutChanged: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onResetActualSize: () -> Void
    let onRotate90: () -> Void
    let onApplyImageEffect: (VisionImageEffect) -> Void
    let onToggleAnnotationMode: () -> Void
    let onToggleInPlaceTranslation: () -> Void
    let onToggleOCRSidebar: () -> Void
    let onToggleShadow: () -> Void
    let onToggleClickThrough: () -> Void
    let onCopyImage: () -> Void
    let onSaveImage: () -> Void
    let onClose: () -> Void

    private let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white
    ]

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            // Row 1: Outer Main Black Icon Bar
            HStack(spacing: 2) {
                InstantBlackIconButton(icon: "minus.magnifyingglass", tooltip: "缩小", action: onZoomOut)
                InstantBlackIconButton(icon: "plus.magnifyingglass", tooltip: "放大", action: onZoomIn)
                InstantBlackIconButton(icon: "1.magnifyingglass", tooltip: "1:1 实际大小", action: onResetActualSize)
                InstantBlackIconButton(icon: "rotate.right", tooltip: "旋转 90° (R)", action: onRotate90)

                pinDivider

                InstantBlackIconButton(
                    icon: "drop.halffull",
                    tooltip: "背景虚化",
                    action: { onApplyImageEffect(.blurBackground) }
                )

                InstantBlackIconButton(
                    icon: "person.crop.rectangle",
                    tooltip: "提取主体（透明背景）",
                    action: { onApplyImageEffect(.extractSubject) }
                )

                pinDivider

                InstantBlackIconButton(
                    icon: "pencil.and.outline",
                    isSelected: vm.isAnnotating,
                    tooltip: "标注贴图",
                    action: onToggleAnnotationMode
                )

                InstantBlackIconButton(
                    icon: "wechat:translate",
                    isHighlightedGreen: vm.isInPlaceTranslated,
                    tooltip: "翻译",
                    action: onToggleInPlaceTranslation
                )

                InstantBlackIconButton(
                    icon: "wechat:ocr",
                    isHighlightedGreen: vm.showOCRSidebar,
                    tooltip: "提取文字",
                    action: onToggleOCRSidebar
                )

                pinDivider

                InstantBlackIconButton(
                    icon: "shadow",
                    isSelected: vm.hasWindowShadow,
                    tooltip: vm.hasWindowShadow ? "取消阴影" : "开启阴影",
                    action: onToggleShadow
                )

                InstantBlackIconButton(
                    icon: "hand.point.up.braille",
                    isSelected: vm.isClickThrough,
                    tooltip: "鼠标穿透",
                    action: onToggleClickThrough
                )

                InstantBlackIconButton(icon: "doc.on.doc", tooltip: "复制图像 (⌘C)", action: onCopyImage)
                InstantBlackIconButton(icon: "square.and.arrow.down", tooltip: "保存图片 (⌘S)", action: onSaveImage)
                InstantBlackIconButton(icon: "xmark", tooltip: "关闭贴图 (Esc)", action: onClose)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                    )
            )
            .padding(.top, 28) // Space for 0ms instant hover tooltips above buttons

            // Row 2: Outer Annotation Sub-Toolbar when annotation mode is active
            if vm.isAnnotating {
                HStack(spacing: 2) {
                    ForEach(SnipAnnotationTool.allCases.filter { $0 != .selectMove }, id: \.id) { tool in
                        InstantBlackIconButton(
                            icon: tool.iconName,
                            isSelected: vm.activeTool == tool,
                            tooltip: tool.rawValue,
                            action: {
                                vm.commitInlineTextIfNeeded()
                                vm.activeTool = tool
                                onSubbarLayoutChanged()
                            }
                        )
                    }

                    pinDivider

                    InstantBlackIconButton(
                        icon: "arrow.uturn.backward",
                        isDisabled: vm.annotations.isEmpty,
                        tooltip: "撤销 (⌘Z)",
                        action: { vm.undoAnnotation() }
                    )

                    if vm.activeTool == .text {
                        pinDivider
                        InstantBlackIconButton(
                            icon: "glyph:B",
                            isSelected: vm.textBold,
                            tooltip: "加粗",
                            action: { vm.textBold.toggle() }
                        )
                        InstantBlackIconButton(
                            icon: "glyph:I",
                            isSelected: vm.textItalic,
                            tooltip: "斜体",
                            action: { vm.textItalic.toggle() }
                        )
                        InstantBlackIconButton(
                            icon: "minus",
                            isDisabled: vm.textFontSize <= SnipTextStyle.minFontSize,
                            tooltip: "减小字号",
                            action: { vm.textFontSize = SnipTextStyle.steppedSize(vm.textFontSize, up: false) }
                        )
                        Text("\(Int(vm.textFontSize))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                            .frame(minWidth: 24)
                        InstantBlackIconButton(
                            icon: "plus",
                            isDisabled: vm.textFontSize >= SnipTextStyle.maxFontSize,
                            tooltip: "增大字号",
                            action: { vm.textFontSize = SnipTextStyle.steppedSize(vm.textFontSize, up: true) }
                        )
                    }

                    pinDivider

                    ForEach(Array(palette.enumerated()), id: \.offset) { _, nsColor in
                        Button(action: { vm.strokeColor = nsColor }) {
                            Circle()
                                .fill(Color(nsColor: nsColor))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            vm.strokeColor == nsColor
                                                ? SnapLexTheme.toolbarForeground(for: colorScheme)
                                                : SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.35),
                                            lineWidth: vm.strokeColor == nsColor ? 2.0 : 1.0
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                        )
                )
            }
        }
        .padding(.bottom, 4)
        .snapLexAppearance()
        .onHover { hovering in
            onToolbarHoverChanged(hovering)
        }
    }

    private var pinDivider: some View {
        Rectangle()
            .fill(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.18))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }
}

// MARK: - Borderless SwiftUI Root View for Pinned Image (Pure Image + Direct Annotation + Inline Text)

private struct PinnedImageRootView: View {
    @ObservedObject var vm: PinnedWindowViewModel
    @Environment(\.colorScheme) private var colorScheme
    let onImageHoverChanged: (Bool) -> Void
    var onToggleInPlaceTranslation: () -> Void
    var onToggleOCRSidebar: () -> Void
    var onToggleAnnotationMode: () -> Void
    var onToggleShadow: () -> Void
    var onToggleClickThrough: () -> Void
    var onToggleThumbnail: () -> Void
    var onRotate90: () -> Void
    var onFlipHorizontal: () -> Void
    var onCopyImage: () -> Void
    var onSaveImage: () -> Void
    var onClose: () -> Void

    @FocusState private var inlineTextFocused: Bool
    @State private var annotationTransformGesture: PinAnnotationTransformGesture?

    var body: some View {
        ZStack {
            if vm.isMinimized {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: vm.displayedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipped()
                    Image(systemName: "pin.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black)
                        .offset(x: -2, y: -2)
                }
            } else {
                HStack(spacing: 0) {
                    // Pure Borderless Image + Live Annotation Canvas
                    GeometryReader { geo in
                        ZStack {
                            Image(nsImage: vm.displayedImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: geo.size.width, height: geo.size.height)

                            Canvas { context, _ in
                                for item in vm.annotations {
                                    Self.drawSwiftUIAnnotation(item, in: &context)
                                }
                                if let draft = vm.currentDraftAnnotation {
                                    Self.drawSwiftUIAnnotation(draft, in: &context)
                                }
                                if vm.isAnnotating,
                                   let selected = vm.annotations.first(where: { $0.id == vm.selectedAnnotationID }) {
                                    Self.drawSelectionHandles(for: selected, in: &context)
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onAppear {
                                vm.canvasSize = geo.size
                            }
                            .onChange(of: geo.size) { _, newSize in
                                vm.canvasSize = newSize
                            }
                            .allowsHitTesting(vm.isAnnotating)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        handlePinAnnotationDrag(value, in: geo.size)
                                    }
                                    .onEnded { value in
                                        handlePinAnnotationEnd(value, in: geo.size)
                                    }
                            )

                            // Inline Direct Text Input (Zero Popup & Zero Background Color!)
                            if vm.isEditingInlineText {
                                TextField(L10n.string("输入文字"), text: $vm.inlineTextValue)
                                    .textFieldStyle(.plain)
                                    .font(Font(vm.currentTextFont))
                                    .foregroundStyle(Color(nsColor: vm.strokeColor))
                                    .fixedSize()
                                    .frame(minWidth: 60, alignment: .leading)
                                    .position(
                                        x: min(max(40, vm.inlineTextOrigin.x + 30), max(40, geo.size.width - 40)),
                                        y: min(max(16, vm.inlineTextOrigin.y), max(16, geo.size.height - 16))
                                    )
                                    .focused($inlineTextFocused)
                                    .onSubmit {
                                        vm.commitInlineTextIfNeeded()
                                    }
                                    .onAppear {
                                        inlineTextFocused = true
                                    }
                            }

                            // Loading / Status HUD
                            if vm.isTranslatingInPlace {
                                VStack {
                                    Spacer()
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text(L10n.string("正在原位贴合翻译..."))
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(SnapLexTheme.toolbarBackground(for: colorScheme)))
                                    Spacer()
                                }
                            } else if let hud = vm.hudMessage {
                                VStack {
                                    Spacer()
                                    Text(hud)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4.5)
                                        .background(Capsule().fill(SnapLexTheme.toolbarBackground(for: colorScheme)))
                                        .padding(.bottom, 8)
                                }
                            }
                        }
                    }

                    // Right: Optional Image 1 Selectable OCR Text Drawer
                    if vm.showOCRSidebar {
                        Divider()
                        ocrRightDrawerView
                            .frame(width: 290)
                    }
                }
            }
        }
        .onHover { hovering in
            onImageHoverChanged(hovering)
        }
        .snapLexAppearance()
        .translationTask(vm.translationConfiguration) { session in
            guard let requestID = vm.pendingTranslationID,
                  let sourceImage = vm.pendingTranslationImage,
                  !vm.pendingTranslationBlocks.isEmpty else { return }

            do {
                try await session.prepareTranslation()
                guard vm.pendingTranslationID == requestID else { return }

                let sourceCode = vm.pendingTranslationSourceCode
                var blocks = vm.pendingTranslationBlocks
                let translatableBlocks = blocks.filter {
                    NativeTranslationSupport.sourceLanguageCode(for: $0.originalText) == sourceCode
                }
                let requests = translatableBlocks.map {
                    TranslationSession.Request(sourceText: $0.originalText, clientIdentifier: $0.id.uuidString)
                }
                var translatedByID: [String: String] = [:]
                if !requests.isEmpty {
                    let responses = try await session.translations(from: requests)
                    guard vm.pendingTranslationID == requestID else { return }
                    for response in responses {
                        if let id = response.clientIdentifier {
                            translatedByID[id] = response.targetText
                        }
                    }
                }

                for index in blocks.indices {
                    if NativeTranslationSupport.sourceLanguageCode(for: blocks[index].originalText) == sourceCode {
                        blocks[index].translatedText = translatedByID[blocks[index].id.uuidString] ?? blocks[index].originalText
                    } else if blocks[index].translatedText.isEmpty {
                        blocks[index].translatedText = blocks[index].originalText
                    }
                }

                vm.pendingTranslationBlocks = blocks
                if !vm.pendingTranslationSourceCodes.isEmpty {
                    let nextSourceCode = vm.pendingTranslationSourceCodes.removeFirst()
                    vm.pendingTranslationSourceCode = nextSourceCode
                    vm.translationConfiguration = NativeTranslationSupport.makeConfiguration(
                        source: nextSourceCode,
                        target: vm.pendingTranslationTargetCode
                    )
                    return
                }

                let originalText = blocks.map(\.originalText).joined(separator: "\n")
                let translatedText = blocks.map(\.translatedText).joined(separator: "\n")
                vm.recordCompletedScreenshotTranslation(blocks: blocks)
                let renderedImage = InPlaceOCRService.renderTranslatedBlocksOnImage(baseImage: sourceImage, blocks: blocks)
                vm.cachedInPlaceResult = InPlaceOCRResult(
                    blocks: blocks,
                    fullOriginalText: originalText,
                    fullTranslatedText: translatedText,
                    renderedTranslatedImage: renderedImage
                )
                vm.ocrBlocks = blocks
                vm.isTranslatingInPlace = false
                vm.rebuildDisplayedImage()
                vm.showHUD(L10n.string("✓ 原位翻译完成"))
            } catch {
                guard vm.pendingTranslationID == requestID else { return }
                vm.isTranslatingInPlace = false
                vm.isInPlaceTranslated = false
                vm.showHUD(L10n.format("系统翻译失败：%@", NativeTranslationSupport.userFacingError(for: error)))
            }
        }
        .contextMenu {
            Button(L10n.string(vm.isInPlaceTranslated ? "还原原图 ([文A])" : "图片原位贴合翻译 ([文A])")) {
                onToggleInPlaceTranslation()
            }
            Button(L10n.string(vm.showOCRSidebar ? "关闭右侧提取文字栏 ([文])" : "右侧提取图中文字 ([文])")) {
                onToggleOCRSidebar()
            }
            Button(L10n.string(vm.isAnnotating ? "完成贴图标注" : "在贴图上直接标注")) {
                onToggleAnnotationMode()
            }
            Divider()
            Button(L10n.string("复制图像 (⌘C)")) { onCopyImage() }
            Button(L10n.string("保存图片 (⌘S)")) { onSaveImage() }
            Divider()
            Button(L10n.string("顺时针旋转 90° (R)")) { onRotate90() }
            Button(L10n.string("水平镜像翻转 (H)")) { onFlipHorizontal() }
            Button(L10n.string(vm.hasWindowShadow ? "取消窗口阴影" : "开启窗口阴影")) { onToggleShadow() }
            Button(L10n.string(vm.isMinimized ? "展开贴图 (双击)" : "折叠为小图标 (双击)")) { onToggleThumbnail() }
            Button(L10n.string(vm.isClickThrough ? "解除鼠标穿透" : "开启鼠标穿透 (右上角可随时退出)")) { onToggleClickThrough() }
            Divider()
            Button(L10n.string("关闭贴图 (Esc)"), role: .destructive) { onClose() }
        }
    }

    // MARK: - Pin Annotation Drawing & Gesture Handlers

    private func handlePinAnnotationDrag(_ value: DragGesture.Value, in size: CGSize) {
        guard vm.isAnnotating else { return }
        handlePinAnnotationTransformDrag(value)
        if annotationTransformGesture != nil { return }
        let start = value.startLocation
        let curr = value.location

        if vm.activeTool == .selectMove { return }

        if vm.activeTool == .text || vm.activeTool == .counter {
            return
        }

        if vm.currentDraftAnnotation == nil {
            vm.commitInlineTextIfNeeded()
            vm.currentDraftAnnotation = SnipAnnotationItem(
                tool: vm.activeTool,
                startPoint: start,
                endPoint: curr,
                points: [start, curr],
                color: vm.strokeColor,
                lineWidth: vm.strokeWidth
            )
        } else {
            vm.currentDraftAnnotation?.endPoint = curr
            if vm.activeTool == .pencil || vm.activeTool == .marker {
                vm.currentDraftAnnotation?.appendFreehandPoint(curr)
            }
        }
    }

    private func handlePinAnnotationEnd(_ value: DragGesture.Value, in size: CGSize) {
        guard vm.isAnnotating else { return }
        if annotationTransformGesture != nil {
            annotationTransformGesture = nil
            return
        }
        let pt = value.location

        if vm.activeTool == .counter {
            let item = SnipAnnotationItem(
                tool: .counter,
                startPoint: pt,
                endPoint: pt,
                color: vm.strokeColor,
                lineWidth: vm.strokeWidth,
                counterNumber: vm.nextCounterNumber
            )
            vm.nextCounterNumber += 1
            vm.annotations.append(item)
            vm.redoStack.removeAll()
            return
        }

        if vm.activeTool == .text {
            vm.commitInlineTextIfNeeded()
            vm.inlineTextOrigin = pt
            vm.inlineTextValue = ""
            vm.isEditingInlineText = true
            return
        }

        if let draft = vm.currentDraftAnnotation {
            vm.annotations.append(draft)
            vm.redoStack.removeAll()
            vm.currentDraftAnnotation = nil
        }
    }

    private func handlePinAnnotationTransformDrag(_ value: DragGesture.Value) {
        let start = value.startLocation
        let current = value.location

        if case nil = annotationTransformGesture {
            vm.commitInlineTextIfNeeded()

            if let selectedIndex = vm.annotations.firstIndex(where: { $0.id == vm.selectedAnnotationID }),
               let handle = AnnotationGeometry.hitTestHandle(at: start, for: vm.annotations[selectedIndex], yAxisDown: true) {
                let item = vm.annotations[selectedIndex]
                switch handle {
                case .rotate:
                    let center = item.transformCenter
                    let angle = atan2(start.y - center.y, start.x - center.x)
                    annotationTransformGesture = .rotate(id: item.id, initial: item, center: center, startAngle: angle)
                case .resize(let resizeHandle):
                    let anchor = AnnotationGeometry.oppositeAnchor(
                        for: resizeHandle,
                        in: item.selectionBounds,
                        yAxisDown: true
                    )
                    let distance = max(4, hypot(start.x - anchor.x, start.y - anchor.y))
                    annotationTransformGesture = .resize(id: item.id, initial: item, anchor: anchor, startDistance: distance)
                }
            } else if let index = vm.annotations.indices.reversed().first(where: {
                vm.annotations[$0].contains(start)
            }) {
                let item = vm.annotations[index]
                if vm.selectedAnnotationID == item.id {
                    annotationTransformGesture = .move(id: item.id, initial: item, start: start)
                } else {
                    vm.selectedAnnotationID = item.id
                    annotationTransformGesture = .selectOnly
                }
            } else {
                vm.selectedAnnotationID = nil
                if vm.activeTool == .selectMove {
                    annotationTransformGesture = .ignored
                }
            }
        }

        guard let gesture = annotationTransformGesture else { return }
        let updated: SnipAnnotationItem
        let itemID: UUID
        switch gesture {
        case .ignored, .selectOnly:
            return
        case .move(let id, let initial, let origin):
            itemID = id
            updated = initial.translated(by: CGPoint(x: current.x - origin.x, y: current.y - origin.y))
        case .resize(let id, let initial, let anchor, let startDistance):
            itemID = id
            let currentDistance = hypot(current.x - anchor.x, current.y - anchor.y)
            updated = initial.scaled(by: currentDistance / startDistance, around: anchor)
        case .rotate(let id, let initial, let center, let startAngle):
            itemID = id
            let currentAngle = atan2(current.y - center.y, current.x - center.x)
            updated = initial.rotated(by: (currentAngle - startAngle) * 180 / .pi)
        }

        guard let index = vm.annotations.firstIndex(where: { $0.id == itemID }) else { return }
        vm.annotations[index] = updated
        vm.selectedAnnotationID = itemID
    }

    fileprivate static func drawSwiftUIAnnotation(_ item: SnipAnnotationItem, in context: inout GraphicsContext) {
        if abs(item.rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.001 {
            context.drawLayer { layer in
                let center = item.transformCenter
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .degrees(Double(item.rotationDegrees)))
                layer.translateBy(x: -center.x, y: -center.y)
                drawUnrotatedSwiftUIAnnotation(item, in: &layer)
            }
        } else {
            drawUnrotatedSwiftUIAnnotation(item, in: &context)
        }
    }

    private static func drawUnrotatedSwiftUIAnnotation(_ item: SnipAnnotationItem, in context: inout GraphicsContext) {
        let color = Color(nsColor: item.color)
        let rect = item.boundingRect

        switch item.tool {
        case .selectMove:
            break
        case .rectangle:
            let path = Path(rect)
            context.stroke(path, with: .color(color), lineWidth: item.lineWidth)
        case .ellipse:
            let path = Path(ellipseIn: rect)
            context.stroke(path, with: .color(color), lineWidth: item.lineWidth)
        case .line:
            var path = Path()
            path.move(to: item.startPoint)
            path.addLine(to: item.endPoint)
            context.stroke(path, with: .color(color), lineWidth: item.lineWidth)
        case .arrow:
            var path = Path()
            path.move(to: item.startPoint)
            path.addLine(to: item.endPoint)
            context.stroke(path, with: .color(color), lineWidth: item.lineWidth)
            let dx = item.endPoint.x - item.startPoint.x
            let dy = item.endPoint.y - item.startPoint.y
            let len = hypot(dx, dy)
            if len > 4 {
                let angle = atan2(dy, dx)
                let headLen = max(12.0, item.lineWidth * 3.5)
                let headAngle: CGFloat = .pi / 6.5
                var head = Path()
                head.move(to: item.endPoint)
                head.addLine(to: CGPoint(
                    x: item.endPoint.x - headLen * cos(angle - headAngle),
                    y: item.endPoint.y - headLen * sin(angle - headAngle)
                ))
                head.addLine(to: CGPoint(
                    x: item.endPoint.x - headLen * cos(angle + headAngle),
                    y: item.endPoint.y - headLen * sin(angle + headAngle)
                ))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
        case .pencil:
            guard item.points.count > 1 else { break }
            let path = Path(item.freehandPath)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
        case .marker:
            guard item.points.count > 1 else { break }
            let path = Path(item.freehandPath)
            context.stroke(path, with: .color(color.opacity(0.36)), style: StrokeStyle(lineWidth: max(14, item.lineWidth * 3.5), lineCap: .butt, lineJoin: .round))
        case .mosaic, .blur:
            let path = Path(rect)
            context.fill(path, with: .color(Color.gray.opacity(0.55)))
        case .counter:
            let r = max(13, item.lineWidth * 3)
            let badge = CGRect(x: item.startPoint.x - r, y: item.startPoint.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: badge), with: .color(color))
            context.draw(
                Text("\(item.counterNumber)").font(.system(size: max(13, item.lineWidth * 3), weight: .bold)).foregroundStyle(.white),
                at: item.startPoint
            )
        case .text:
            guard !item.text.isEmpty else { break }
            context.draw(
                Text(item.text)
                    .font(Font(item.textFont))
                    .foregroundStyle(color),
                at: item.startPoint,
                anchor: .leading
            )
        }
    }

    private static func drawSelectionHandles(for item: SnipAnnotationItem, in context: inout GraphicsContext) {
        let rect = item.selectionBounds
        var outline = Path()
        outline.addRect(rect)
        context.stroke(outline, with: .color(.white), lineWidth: 1)
        context.stroke(outline, with: .color(.accentColor), lineWidth: 0.7)

        let rotatePoint = AnnotationGeometry.rotateHandlePoint(for: item, yAxisDown: true)
        var connector = Path()
        connector.move(to: CGPoint(x: rect.midX, y: rect.minY))
        connector.addLine(to: rotatePoint)
        context.stroke(connector, with: .color(.white), lineWidth: 1.5)

        let rotateRect = CGRect(x: rotatePoint.x - 5, y: rotatePoint.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rotateRect), with: .color(.white))
        context.stroke(Path(ellipseIn: rotateRect), with: .color(.accentColor), lineWidth: 1.5)

        for handle in ResizeHandlePosition.allCases {
            let point = AnnotationGeometry.point(for: handle, in: rect, yAxisDown: true)
            let knob = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(Path(roundedRect: knob, cornerRadius: 1.5), with: .color(.white))
            context.stroke(Path(roundedRect: knob, cornerRadius: 1.5), with: .color(.accentColor), lineWidth: 1.2)
        }
    }

    // MARK: - Right-Side OCR Text Drawer (Image 1)

    private var ocrRightDrawerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string(vm.showTranslatedInSidebar ? "译文内容" : "提取文字 (OCR)"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.cachedInPlaceResult != nil {
                    Button(L10n.string(vm.showTranslatedInSidebar ? "看原文" : "看译文")) {
                        vm.showTranslatedInSidebar.toggle()
                        if let cached = vm.cachedInPlaceResult {
                            vm.ocrSidebarText = vm.showTranslatedInSidebar
                                ? cached.fullTranslatedText
                                : cached.fullOriginalText
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
                }
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.ocrSidebarText, forType: .string)
                    vm.showHUD(L10n.string("已复制全部文字"))
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if vm.isExtractingOCR {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                    Text(L10n.string("正在识别图中文字..."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                TextEditor(text: $vm.ocrSidebarText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum PinAnnotationTransformGesture {
    case move(id: UUID, initial: SnipAnnotationItem, start: CGPoint)
    case resize(id: UUID, initial: SnipAnnotationItem, anchor: CGPoint, startDistance: CGFloat)
    case rotate(id: UUID, initial: SnipAnnotationItem, center: CGPoint, startAngle: CGFloat)
    case selectOnly
    case ignored
}
