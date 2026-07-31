import SwiftUI

/// The Settings scene (⌘,): General editing preferences and Appearance.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("General") {
                Toggle("Autosave documents", isOn: $settings.autosaveEnabled)
                Toggle("Autoformat as you type", isOn: $settings.autoformatEnabled)
                Toggle("Typewriter scrolling", isOn: $settings.typewriterModeEnabled)
            }
            Section("Appearance") {
                Picker("Theme:", selection: $settings.appearance) {
                    Text("System").tag(AppAppearance.system)
                    Text("Light").tag(AppAppearance.light)
                    Text("Dark").tag(AppAppearance.dark)
                }
                Picker("Editor font:", selection: $settings.editorFontChoice) {
                    Text("System").tag(EditorFontChoice.system)
                    Text("New York (serif)").tag(EditorFontChoice.serif)
                    Text("SF Mono").tag(EditorFontChoice.monospaced)
                }
                Stepper(
                    "Font size: \(Int(settings.editorFontSize)) pt",
                    value: $settings.editorFontSize,
                    in: AppSettings.fontSizeRange,
                    step: 1
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
