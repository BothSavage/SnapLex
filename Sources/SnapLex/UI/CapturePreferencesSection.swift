import AppKit
import SwiftUI

struct CapturePreferencesSection: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsNamingRules = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeaderLabel(title: L10n.string("截图与贴图"))
                Spacer()
                Button(L10n.string("恢复截图与贴图默认")) { restoreCaptureDefaults() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
            }

            VStack(spacing: 0) {
                SettingsChoiceRow(title: L10n.string("选区边框宽度"), subtitle: L10n.string("像素")) {
                    Stepper(value: doubleBinding(\.borderWidth), in: 1...12, step: 1) {
                        Text("\(Int(settings.capturePreferences.borderWidth))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .fixedSize()
                }
                DividerLine()
                SettingsChoiceRow(title: L10n.string("遮罩颜色"), subtitle: L10n.string("遮罩以外的区域")) {
                    ColorPicker("", selection: maskColor, supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 44)
                }
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("显示调整锚点"),
                    subtitle: L10n.string("拖动锚点可以改变选区大小"),
                    isOn: boolBinding(\.showAnchors)
                )
                DividerLine()
                SettingsChoiceRow(title: L10n.string("锚点边框颜色")) {
                    ColorPicker("", selection: anchorColor, supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 44)
                }
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("放大镜显示遮罩"),
                    subtitle: L10n.string("放大镜里也叠上选区外的遮罩"),
                    isOn: boolBinding(\.magnifierShowsMask)
                )
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("放大镜显示边框"),
                    subtitle: L10n.string("放大镜里显示选区边框"),
                    isOn: boolBinding(\.magnifierShowsBorder)
                )
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("放大镜显示锚点"),
                    subtitle: L10n.string("放大镜里显示调整锚点"),
                    isOn: boolBinding(\.magnifierShowsAnchors)
                )
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("显示全屏十字线"),
                    subtitle: L10n.string("跟随光标画满屏十字线"),
                    isOn: boolBinding(\.showCrossLines)
                )
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("显示快捷键提示"),
                    subtitle: L10n.string("在截图左下角显示按键说明"),
                    isOn: boolBinding(\.showKeyTips)
                )
            }
            .cardSurface(colorScheme)

            VStack(spacing: 0) {
                MonochromeToggleRow(
                    title: L10n.string("贴图窗口阴影"),
                    subtitle: L10n.string("新建贴图时带窗口阴影"),
                    isOn: boolBinding(\.pinShadow)
                )
                DividerLine()
                SettingsChoiceRow(title: L10n.string("贴图默认透明度"), subtitle: "%") {
                    numberControl(intBinding(\.pinOpacityPercent), range: 15...100, step: 5)
                }
                DividerLine()
                SettingsChoiceRow(title: L10n.string("贴图最大边长"), subtitle: L10n.string("像素")) {
                    numberControl(intBinding(\.pinMaxSide), range: 200...20000, step: 100)
                }
                DividerLine()
                SettingsChoiceRow(title: L10n.string("缩略图尺寸"), subtitle: L10n.string("像素")) {
                    numberControl(intBinding(\.thumbnailSize), range: 24...240, step: 2)
                }
            }
            .cardSurface(colorScheme)

            VStack(spacing: 0) {
                SettingsChoiceRow(title: L10n.string("手动保存文件名")) {
                    TextField("", text: patternBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                DividerLine()
                SettingsChoiceRow(title: L10n.string("命名预览")) {
                    Text(namePreview)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
                if showsNamingRules {
                    Text(L10n.string("文件名里用 $yyyy$、$MM$、$dd$、$HH$、$mm$、$ss$ 表示时间，也可以连写成 $yyyy-MM-dd_HH-mm-ss$。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                DividerLine()
                HStack {
                    Button(L10n.string("命名规则")) { showsNamingRules.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("快速保存时显示提示"),
                    subtitle: L10n.string("保存到快速保存文件夹后显示文件名"),
                    isOn: boolBinding(\.quickSaveNotification)
                )
                DividerLine()
                folderRow(
                    title: L10n.string("快速保存文件夹"),
                    path: settings.capturePreferences.quickSaveDirectoryURL().path,
                    choose: { chooseFolder(fallback: settings.capturePreferences.quickSaveDirectoryURL()) { setDirectory(\.quickSaveDirectory, $0) } },
                    open: { openFolder(settings.capturePreferences.quickSaveDirectoryURL()) }
                )
                DividerLine()
                MonochromeToggleRow(
                    title: L10n.string("自动保存每次截图"),
                    subtitle: L10n.string("完成截图后额外保存一份 PNG"),
                    isOn: boolBinding(\.autoSaveEnabled)
                )
                DividerLine()
                folderRow(
                    title: L10n.string("自动保存文件夹"),
                    path: settings.capturePreferences.autoSaveDirectoryURL().path,
                    choose: { chooseFolder(fallback: settings.capturePreferences.autoSaveDirectoryURL()) { setDirectory(\.autoSaveDirectory, $0) } },
                    open: { openFolder(settings.capturePreferences.autoSaveDirectoryURL()) }
                )
            }
            .cardSurface(colorScheme)
        }
    }

    private var namePreview: String {
        SnapPreferences.fileName(pattern: settings.capturePreferences.fileNamePattern, at: Date())
    }

    private var patternBinding: Binding<String> {
        Binding(
            get: { settings.capturePreferences.fileNamePattern },
            set: { value in
                var preferences = settings.capturePreferences
                preferences.fileNamePattern = value
                settings.capturePreferences = preferences
            }
        )
    }

    private var maskColor: Binding<Color> {
        colorBinding(
            red: \.maskRed, green: \.maskGreen, blue: \.maskBlue, alpha: \.maskAlpha
        )
    }

    private var anchorColor: Binding<Color> {
        colorBinding(
            red: \.anchorBorderRed, green: \.anchorBorderGreen, blue: \.anchorBorderBlue, alpha: \.anchorBorderAlpha
        )
    }

    private func numberControl(_ value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func folderRow(title: String, path: String, choose: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button(L10n.string("打开文件夹"), action: open)
                Button(L10n.string("选择文件夹"), action: choose)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func boolBinding(_ keyPath: WritableKeyPath<SnapPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.capturePreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = settings.capturePreferences
                preferences[keyPath: keyPath] = newValue
                settings.capturePreferences = preferences
            }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<SnapPreferences, Int>) -> Binding<Int> {
        Binding(
            get: { settings.capturePreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = settings.capturePreferences
                preferences[keyPath: keyPath] = newValue
                settings.capturePreferences = preferences
            }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<SnapPreferences, Double>) -> Binding<Double> {
        Binding(
            get: { settings.capturePreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = settings.capturePreferences
                preferences[keyPath: keyPath] = newValue
                settings.capturePreferences = preferences
            }
        )
    }

    private func colorBinding(
        red: WritableKeyPath<SnapPreferences, Double>,
        green: WritableKeyPath<SnapPreferences, Double>,
        blue: WritableKeyPath<SnapPreferences, Double>,
        alpha: WritableKeyPath<SnapPreferences, Double>
    ) -> Binding<Color> {
        Binding(
            get: {
                let preferences = settings.capturePreferences
                return Color(
                    .sRGB,
                    red: preferences[keyPath: red],
                    green: preferences[keyPath: green],
                    blue: preferences[keyPath: blue],
                    opacity: preferences[keyPath: alpha]
                )
            },
            set: { color in
                let resolved = NSColor(color).usingColorSpace(.sRGB)
                var preferences = settings.capturePreferences
                preferences[keyPath: red] = Double(resolved?.redComponent ?? 0)
                preferences[keyPath: green] = Double(resolved?.greenComponent ?? 0)
                preferences[keyPath: blue] = Double(resolved?.blueComponent ?? 0)
                preferences[keyPath: alpha] = Double(resolved?.alphaComponent ?? 1)
                settings.capturePreferences = preferences
            }
        )
    }

    private func chooseFolder(fallback: URL, assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = fallback
        panel.prompt = L10n.string("选择文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assign(url.path)
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func setDirectory(_ keyPath: WritableKeyPath<SnapPreferences, String>, _ path: String) {
        var preferences = settings.capturePreferences
        preferences[keyPath: keyPath] = path
        settings.capturePreferences = preferences
    }

    private func restoreCaptureDefaults() {
        let current = settings.capturePreferences
        var reset = SnapPreferences.standard
        reset.checkUpdatesOnStartup = current.checkUpdatesOnStartup
        reset.updateDelaySeconds = current.updateDelaySeconds
        reset.updateIntervalHours = current.updateIntervalHours
        reset.periodicUpdatesEnabled = current.periodicUpdatesEnabled
        settings.capturePreferences = reset
    }
}

private extension View {
    func cardSurface(_ colorScheme: ColorScheme) -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}
