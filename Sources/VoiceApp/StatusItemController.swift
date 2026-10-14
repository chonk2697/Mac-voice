import AppKit
import SwiftUI
import VoiceAnalysis

/// The menu bar item: live compact readout, click to open the panel.
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor: VoiceMonitor
    private var refreshTask: Task<Void, Never>?

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
        let text = BarText.make(monitor: monitor)
        button.attributedTitle = text
        button.setAccessibilityValue(text.string)
    }
}

/// Builds the compact attributed string shown in the menu bar.
enum BarText {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    static func make(monitor: VoiceMonitor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let indicators = Indicator.allCases.filter {
            monitor.settings.enabledIndicators.contains($0) && monitor.settings.barIndicators.contains($0)
        }

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

    static func fragment(_ indicator: Indicator, monitor: VoiceMonitor) -> (String, Status) {
        func status(_ inRange: Bool?) -> Status {
            guard let inRange else { return .neutral }
            return inRange ? .inRange : .outOfRange
        }
        switch indicator {
        case .pitch:
            guard let pitch = monitor.current[.pitch] else { return ("–Hz", .unmeasured) }
            return ("\(Int(pitch.rounded()))Hz", status(monitor.isInRange(.pitch)))
        case .formants:
            let values = [Metric.f1, .f2, .f3].compactMap { monitor.current[$0] }
            guard values.count == 3 else { return ("F –", .unmeasured) }
            return ("F" + values.map { "\(Int($0.rounded()))" }.joined(separator: "·"), .neutral)
        case .resonance:
            guard let gauge = monitor.gauge(for: .resonance) else { return ("R–", .unmeasured) }
            return ("R\(Int(gauge.rounded()))", status(monitor.isInRange(.resonance)))
        case .weight:
            guard let gauge = monitor.gauge(for: .weight) else { return ("W–", .unmeasured) }
            return ("W\(Int(gauge.rounded()))", status(monitor.isInRange(.weight)))
        case .brightness:
            if let trend = monitor.brightnessTrend {
                return (String(format: "B%+.0f", trend), .neutral)
            }
            guard let alpha = monitor.current[.alphaRatio] else { return ("B–", .unmeasured) }
            return (String(format: "B%.0f", alpha), .neutral)
        }
    }
}
