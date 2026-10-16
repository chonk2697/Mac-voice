import AppKit
import SwiftUI
import VoiceAnalysis

/// The menu bar item: live compact readout, click to open the panel.
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor: VoiceMonitor
    private var refreshTask: Task<Void, Never>?
    private var sizedForIndicators: Set<Indicator>?

    init(monitor: VoiceMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Voice indicators")
        }

        let hosting = NSHostingController(rootView: PanelView(monitor: monitor))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        render()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(1000 / VoiceMonitor.displayRate)))
                self?.render()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let indicators = BarText.indicators(for: monitor.settings)
        if sizedForIndicators != indicators {
            // Every fragment has a constant character count in a monospaced
            // font, so the widest possible string has the same width as any
            // other. Pin the item to it so neighbours never shift.
            let widest = BarText.widestString(for: indicators)
            let textWidth = NSAttributedString(string: widest, attributes: [.font: BarText.font]).size().width
            let imageWidth = button.image?.size.width ?? 0
            statusItem.length = ceil(textWidth + imageWidth + 18)
            sizedForIndicators = indicators
        }
        let text = BarText.make(monitor: monitor)
        button.attributedTitle = text
        button.setAccessibilityValue(text.string)
    }
}

/// Builds the compact attributed string shown in the menu bar.
enum BarText {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)

    /// Indicators shown in the bar. Independent of the panel's own toggles.
    static func indicators(for settings: AppSettings) -> Set<Indicator> {
        settings.barIndicators
    }

    /// A string with the same character count as any live readout for these indicators.
    static func widestString(for indicators: Set<Indicator>) -> String {
        let ordered = Indicator.allCases.filter(indicators.contains)
        guard !ordered.isEmpty else { return "●" }
        return ordered.map { placeholder($0) }.joined(separator: " ")
    }

    static func placeholder(_ indicator: Indicator) -> String {
        switch indicator {
        case .pitch: "000Hz"
        case .formants: "F0000 0000 0000"
        case .resonance: "R000"
        case .weight: "W000"
        case .brightness: "B+00"
        }
    }

    static func make(monitor: VoiceMonitor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let indicators = Indicator.allCases.filter(BarText.indicators(for: monitor.settings).contains)

        func append(_ string: String, color: NSColor) {
            if result.length > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            result.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }

        switch monitor.state {
        case .paused: append("paused", color: .secondaryLabelColor); return result
        case .denied: append("no mic", color: .systemRed); return result
        case .failed: append("error", color: .systemRed); return result
        default: break
        }
        guard !indicators.isEmpty else {
            append(monitor.isVoiced ? "●" : "○", color: .secondaryLabelColor)
            return result
        }

        for indicator in indicators {
            let (string, status) = fragment(indicator, monitor: monitor)
            append(string, color: color(for: status, voiced: monitor.isVoiced))
        }
        return result
    }

    enum Status { case inRange, outOfRange, neutral, unmeasured }

    static func color(for status: Status, voiced: Bool) -> NSColor {
        switch status {
        case .inRange: .systemGreen
        case .outOfRange: .systemOrange
        case .neutral: .labelColor
        case .unmeasured: .tertiaryLabelColor
        }
    }

    /// Each fragment always has the character count of its placeholder, so the
    /// readout never changes width while values move.
    static func fragment(_ indicator: Indicator, monitor: VoiceMonitor) -> (String, Status) {
        func status(_ inRange: Bool?) -> Status {
            guard let inRange else { return .neutral }
            return inRange ? .inRange : .outOfRange
        }
        func digits(_ value: Double, _ width: Int, max: Double = 9999) -> String {
            let clamped = Int(min(max, Swift.max(0, value)).rounded())
            return String(repeating: " ", count: Swift.max(0, width - String(clamped).count)) + String(clamped)
        }
        let dash = "  –"
        switch indicator {
        case .pitch:
            guard let pitch = monitor.current[.pitch] else { return (dash + "Hz", .unmeasured) }
            return (digits(pitch, 3, max: 999) + "Hz", status(monitor.isInRange(.pitch)))
        case .formants:
            let values = [Metric.f1, .f2, .f3].compactMap { monitor.current[$0] }
            guard values.count == 3 else { return ("F   –    –    –", .unmeasured) }
            return ("F" + values.map { digits($0, 4) }.joined(separator: " "), .neutral)
        case .resonance:
            guard let gauge = monitor.gauge(for: .resonance) else { return ("R" + dash, .unmeasured) }
            return ("R" + digits(gauge, 3, max: 100), status(monitor.isInRange(.resonance)))
        case .weight:
            guard let gauge = monitor.gauge(for: .weight) else { return ("W" + dash, .unmeasured) }
            return ("W" + digits(gauge, 3, max: 100), status(monitor.isInRange(.weight)))
        case .brightness:
            let value = monitor.brightnessTrend ?? monitor.current[.alphaRatio]
            guard let value else { return ("B" + dash, .unmeasured) }
            let clamped = Int(min(99, Swift.max(-99, value)).rounded())
            let sign = clamped < 0 ? "-" : "+"
            let magnitude = String(abs(clamped))
            return ("B" + sign + String(repeating: " ", count: Swift.max(0, 2 - magnitude.count)) + magnitude, .neutral)
        }
    }
}
