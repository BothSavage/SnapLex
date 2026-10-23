import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var axTrusted: Bool = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)

    public init() {}

    public var body: some View {
        Form {
            Section("⌨️ 划词悬浮条与触发方式") {
                Toggle("启用「鼠标划词松开后自动弹出胶囊悬浮条」 (需开启辅助功能权限)", isOn: $settings.enableMouseHoverBar)
                Toggle("启用「双击 ⌘C」弹出划词悬浮条 (无需任何权限即可在所有 App 生效)", isOn: $settings.enableDoubleCmdC)

                VStack(alignment: .leading, spacing: 4) {
                    Text("全局快捷键：")
                        .font(.system(size: 12, weight: .medium))
                    Text("• F1 / ⌥ + S ：Snipaste Pro 截图 + 窗口自动识别 + 像素放大镜取色 + 10种标注 + OCR 翻译")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                    Text("• F3 / ⌥ + P ：Snipaste 贴图 (Pin to Screen，支持将截图/剪贴板文字/HEX色卡钉在桌面顶层)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.indigo)
                    Text("• ⇧ + F3     ：恢复上一个关闭的贴图   |   ⌥ + A ：划词直接翻译卡片   |   ⌥ + D ：唤起翻译面板")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("macOS 辅助功能 (Accessibility) 鼠标划词权限：")
                    if axTrusted {
                        Text("✅ 已授权")
                            .foregroundStyle(.green)
                            .fontWeight(.semibold)
                    } else {
                        Text("⚠️ 未授权 (当前可使用双击⌘C或点击右侧授权)")
                            .foregroundStyle(.orange)
                        Button("请求授权") {
                            axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("刷新状态") {
                        axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
                    }
                    .controlSize(.small)
                }
            }

            Section("📚 生词本 SQLite + Markdown 双写配置") {
                HStack {
                    TextField("Markdown 同步目录 (可指向 Obsidian 库)", text: $settings.markdownExportDir)
                        .textFieldStyle(.roundedBorder)
                    Button("选择目录...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.markdownExportDir = url.path
                            VocabularyStore.shared.syncMarkdownFile()
                        }
                    }
                }
                Text("SQLite 库路径：\(VocabularyStore.shared.dbPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Toggle("查询单个生词/短语时自动写入生词本", isOn: $settings.autoSaveSingleWord)
            }

            Section("🤖 大模型接口配置 (未填 Key 时默认使用内置免配极速翻译引擎)") {
                HStack(spacing: 8) {
                    Text("快捷预设：")
                        .font(.system(size: 12, weight: .medium))
                    ForEach(AppSettings.presets) { preset in
                        Button(preset.name) {
                            settings.apiBaseURL = preset.baseURL
                            settings.modelName = preset.defaultModel
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                TextField("API Base URL", text: $settings.apiBaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key (留空则自动使用内置免配极速翻译)", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("模型名称 (Model)", text: $settings.modelName)
                    .textFieldStyle(.roundedBorder)
                TextField("专业语境偏好", text: $settings.domainContextHint)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 500)
    }
}
