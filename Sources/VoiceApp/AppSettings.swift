import Foundation
import Observation
import ServiceManagement
import VoiceAnalysis

/// Which voice the user is training towards. Ranges are starting points
/// drawn from published speaking-voice figures, not clinical targets.
enum TargetPreset: String, CaseIterable, Codable, Identifiable {
    case feminine, masculine, androgynous, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feminine: "Feminine"
        case .masculine: "Masculine"
        case .androgynous: "Androgynous"
        case .custom: "Custom"
        }
    }

    var pitchRange: ClosedRange<Double>? {
        switch self {
        case .feminine: 165...255
        case .masculine: 85...155
        case .androgynous: 145...175
        case .custom: nil
        }
    }

    /// Target band on the 0 to 100 resonance gauge (higher is brighter, smaller tract).
    var resonanceRange: ClosedRange<Double>? {
        switch self {
        case .feminine: 60...100
        case .masculine: 0...40
        case .androgynous: 40...60
        case .custom: nil
        }
    }

    /// Target band on the 0 to 100 weight gauge (higher is heavier).
    var weightRange: ClosedRange<Double>? {
        switch self {
        case .feminine: 0...40
        case .masculine: 60...100
        case .androgynous: 40...60
        case .custom: nil
        }
    }
}

enum ChartWindow: Double, CaseIterable, Codable, Identifiable {
    case thirtySeconds = 30
    case twoMinutes = 120
    case tenMinutes = 600

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .thirtySeconds: "30 s"
        case .twoMinutes: "2 min"
        case .tenMinutes: "10 min"
        }
    }
}

/// User preferences, persisted to UserDefaults as one JSON blob.
@Observable
final class AppSettings {
    private struct Stored: Codable {
        var enabledIndicators: Set<Indicator> = Set(Indicator.allCases)
        var barIndicators: Set<Indicator> = [.pitch, .resonance, .weight]
        var preset: TargetPreset = .feminine
        var customPitchLow: Double = 165
        var customPitchHigh: Double = 255
        var autoIdleEnabled = true
        var autoIdleMinutes = 2
        var chartWindow: ChartWindow = .thirtySeconds
        var baseline: VoiceProfile?
        var calibration = Calibration()
        var inputDeviceUID: String?
    }

    private static let key = "settings"
    @ObservationIgnored private var saving = false

    var enabledIndicators: Set<Indicator> { didSet { save() } }
    var barIndicators: Set<Indicator> { didSet { save() } }
    var preset: TargetPreset { didSet { save() } }
    var customPitchLow: Double { didSet { save() } }
    var customPitchHigh: Double { didSet { save() } }
    var autoIdleEnabled: Bool { didSet { save() } }
    var autoIdleMinutes: Int { didSet { save() } }
    var chartWindow: ChartWindow { didSet { save() } }
    var baseline: VoiceProfile? { didSet { save() } }
    var calibration: Calibration { didSet { save() } }
    /// Core Audio device UID of the chosen input; nil follows the system default.
    var inputDeviceUID: String? { didSet { save() } }

    init() {
        var stored = Stored()
        if let data = UserDefaults.standard.data(forKey: AppSettings.key),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
        enabledIndicators = stored.enabledIndicators
        barIndicators = stored.barIndicators
        preset = stored.preset
        customPitchLow = stored.customPitchLow
        customPitchHigh = stored.customPitchHigh
        autoIdleEnabled = stored.autoIdleEnabled
        autoIdleMinutes = stored.autoIdleMinutes
        chartWindow = stored.chartWindow
        baseline = stored.baseline
        calibration = stored.calibration
        inputDeviceUID = stored.inputDeviceUID
    }

    private func save() {
        let stored = Stored(enabledIndicators: enabledIndicators, barIndicators: barIndicators,
                            preset: preset, customPitchLow: customPitchLow, customPitchHigh: customPitchHigh,
                            autoIdleEnabled: autoIdleEnabled, autoIdleMinutes: autoIdleMinutes,
                            chartWindow: chartWindow, baseline: baseline, calibration: calibration,
                            inputDeviceUID: inputDeviceUID)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }

    var pitchRange: ClosedRange<Double>? {
        preset == .custom ? min(customPitchLow, customPitchHigh)...max(customPitchLow, customPitchHigh)
                          : preset.pitchRange
    }

    /// Launch at login through SMAppService. Only meaningful for the bundled app.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error)")
            }
        }
    }
}
