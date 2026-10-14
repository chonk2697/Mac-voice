import AppKit
import SwiftUI
import VoiceAnalysis

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(settings: delegate.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private var monitor: VoiceMonitor?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = VoiceMonitor(settings: settings)
        self.monitor = monitor
        statusItem = StatusItemController(monitor: monitor)
        Task { await monitor.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Calibration anchors and the custom pitch range. Everything else lives in the panel.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Custom pitch target (Hz)") {
                TextField("Low", value: $settings.customPitchLow, format: .number)
                TextField("High", value: $settings.customPitchHigh, format: .number)
            }
            Section("Resonance gauge: vocal tract length (cm)") {
                TextField("Shown as 0, dark", value: $settings.calibration.darkVocalTractLength, format: .number)
                TextField("Shown as 100, bright", value: $settings.calibration.brightVocalTractLength, format: .number)
            }
            Section("Weight gauge: H1-H2 (dB)") {
                TextField("Shown as 0, light", value: $settings.calibration.lightH1H2, format: .number)
                TextField("Shown as 100, heavy", value: $settings.calibration.heavyH1H2, format: .number)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                Button("Reset calibration") { settings.calibration = Calibration() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.bottom)
    }
}
