import Charts
import SwiftUI
import VoiceAnalysis

/// The panel that opens from the menu bar item.
struct PanelView: View {
    let monitor: VoiceMonitor

    var body: some View {
        @Bindable var settings = monitor.settings
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Target", selection: $settings.preset) {
                ForEach(TargetPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ForEach(Indicator.allCases.filter { settings.enabledIndicators.contains($0) }) { indicator in
                IndicatorRow(indicator: indicator, monitor: monitor)
            }
            if settings.enabledIndicators.isEmpty {
                Text("No indicators enabled. Turn some on below.")
                    .foregroundStyle(.secondary)
            }

            Divider()
            controls
            Divider()
            IndicatorToggles(settings: settings)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
            Text("Voice").font(.headline)
            Spacer()
            LevelMeter(level: monitor.level)
            Text(monitor.state.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(monitor.isPaused ? "Resume" : "Pause") {
                monitor.isPaused ? monitor.resume() : monitor.pause()
            }
            .controlSize(.small)
        }
    }

    private var controls: some View {
        @Bindable var settings = monitor.settings
        return HStack {
            Picker("Window", selection: $settings.chartWindow) {
                ForEach(ChartWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            Spacer()
            if let progress = monitor.baselineProgress {
                ProgressView(value: progress)
                    .frame(width: 70)
                Button("Cancel") { monitor.cancelBaseline() }
                    .controlSize(.small)
            } else {
                Button(monitor.baseline == nil ? "Record baseline" : "Re-record baseline") {
                    monitor.recordBaseline()
                }
                .controlSize(.small)
                .help("Speak normally for \(Int(VoiceMonitor.baselineDuration)) seconds. Only summary numbers are kept, never audio.")
                if monitor.baseline != nil {
                    Button("Clear") { monitor.clearBaseline() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        @Bindable var settings = monitor.settings
        return HStack {
            Toggle("Auto-idle after", isOn: $settings.autoIdleEnabled)
                .toggleStyle(.checkbox)
            Stepper(value: $settings.autoIdleMinutes, in: 1...30) {
                Text("\(settings.autoIdleMinutes) min")
            }
            .disabled(!settings.autoIdleEnabled)
            Spacer()
            SettingsLink { Text("Settings…") }
                .controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .font(.callout)
    }
}

/// Input level as a small bar, so the user can see the mic is live.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        let fraction = max(0, min(1, (level + 60) / 60))
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.secondary).frame(width: 40 * fraction)
        }
        .frame(width: 40, height: 5)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level)) decibels")
    }
}

/// One indicator: current value, target status, drift and a timeline chart.
struct IndicatorRow: View {
    let indicator: Indicator
    let monitor: VoiceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(indicator.title).font(.subheadline.weight(.semibold))
                statusDot
                Spacer()
                Text(valueText)
                    .font(.system(.body, design: .rounded).monospacedDigit().weight(.medium))
                    .foregroundStyle(monitor.isVoiced ? .primary : .secondary)
            }
            if let gauge = monitor.gauge(for: indicator) {
                GaugeBar(value: gauge, target: monitor.targetRange(for: indicator))
            }
            HStack {
                Text(detailText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(driftText).font(.caption).foregroundStyle(.secondary)
            }
            TimelineChart(indicator: indicator, monitor: monitor)
                .frame(height: indicator == .formants ? 70 : 50)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(indicator.title)
        .accessibilityValue(valueText)
    }

    @ViewBuilder private var statusDot: some View {
        if let inRange = monitor.isInRange(indicator) {
            Circle()
                .fill(inRange ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityLabel(inRange ? "In target range" : "Outside target range")
        }
    }

    private var valueText: String {
        let current = monitor.current
        switch indicator {
        case .pitch:
            guard let pitch = current[.pitch] else { return "–" }
            return "\(Int(pitch.rounded())) Hz  \(NoteName.name(forFrequency: pitch))"
        case .formants:
            let values = [Metric.f1, .f2, .f3].compactMap { current[$0] }
            guard values.count == 3 else { return "–" }
            return values.map { "\(Int($0.rounded()))" }.joined(separator: " · ") + " Hz"
        case .resonance:
            guard let gauge = monitor.gauge(for: .resonance) else { return "–" }
            return "\(Int(gauge.rounded()))"
        case .weight:
            guard let gauge = monitor.gauge(for: .weight) else { return "–" }
            return "\(Int(gauge.rounded()))"
        case .brightness:
            guard let alpha = current[.alphaRatio] else { return "–" }
            return String(format: "%.1f dB", alpha)
        }
    }

    private var detailText: String {
        switch indicator {
        case .pitch:
            guard let range = monitor.targetRange(for: .pitch) else { return "No target" }
            return "Target \(Int(range.lowerBound)) to \(Int(range.upperBound)) Hz"
        case .formants:
            if let shift = monitor.formantShift {
                return String(format: "%+.0f %% vs baseline", shift * 100)
            }
            return "F1 · F2 · F3, median of voiced speech"
        case .resonance:
            guard let vtl = monitor.current[.vocalTractLength] else { return "Dark 0 to bright 100" }
            var text = String(format: "Tract %.1f cm · dark 0 to bright 100", vtl)
            if let shift = monitor.formantShift {
                text += String(format: " · formants %+.0f %%", shift * 100)
            }
            return text
        case .weight:
            guard let h1h2 = monitor.current[.h1h2] else { return "Light 0 to heavy 100" }
            return String(format: "H1-H2 %.1f dB · light 0 to heavy 100", h1h2)
        case .brightness:
            if let trend = monitor.brightnessTrend {
                return String(format: "%+.1f dB vs baseline · experimental", trend)
            }
            return "Alpha ratio, higher is brighter · experimental"
        }
    }

    private var driftText: String {
        guard let drift = monitor.drift(for: indicator) else { return "" }
        let unit = indicator.metrics.first?.unit ?? ""
        let arrow = drift > 0 ? "↑" : (drift < 0 ? "↓" : "→")
        let magnitude = indicator == .pitch || indicator == .formants
            ? String(format: "%.0f", abs(drift)) : String(format: "%.1f", abs(drift))
        return "\(arrow) \(magnitude) \(unit) last 10 s vs session"
    }
}

/// Thin horizontal gauge with an optional target band.
struct GaugeBar: View {
    let value: Double
    let target: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let target {
                    Capsule()
                        .fill(Color.green.opacity(0.25))
                        .frame(width: width * (target.upperBound - target.lowerBound) / 100)
                        .offset(x: width * target.lowerBound / 100)
                }
                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(width - 10, width * value / 100 - 5)))
            }
        }
        .frame(height: 10)
    }
}

/// Scrolling history for an indicator over the chosen window.
struct TimelineChart: View {
    let indicator: Indicator
    let monitor: VoiceMonitor

    var body: some View {
        let window = monitor.settings.chartWindow.rawValue
        let now = monitor.now
        Chart {
            if let target = monitor.targetRange(for: indicator), indicator == .pitch {
                RectangleMark(yStart: .value("Low", target.lowerBound), yEnd: .value("High", target.upperBound))
                    .foregroundStyle(Color.green.opacity(0.12))
            }
            ForEach(indicator.metrics, id: \.self) { metric in
                ForEach(monitor.timelinePoints(metric)) { point in
                    LineMark(x: .value("Time", point.time - now), y: .value(metric.rawValue, displayValue(point.value, metric)))
                        .foregroundStyle(by: .value("Metric", metric.rawValue))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: -window...0)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartLegend(.hidden)
    }

    private func displayValue(_ value: Double, _ metric: Metric) -> Double {
        switch indicator {
        case .resonance: monitor.settings.calibration.resonanceGauge(vocalTractLength: value)
        case .weight: monitor.settings.calibration.weightGauge(h1h2: value)
        default: value
        }
    }

    private var yDomain: ClosedRange<Double> {
        switch indicator {
        case .pitch: 60...400
        case .formants: 0...4000
        case .resonance, .weight: 0...100
        case .brightness: -40...10
        }
    }
}

/// Which indicators appear in the panel and in the menu bar.
struct IndicatorToggles: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Show").font(.caption).foregroundStyle(.secondary)
                Text("Panel").font(.caption).foregroundStyle(.secondary)
                Text("Menu bar").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Indicator.allCases) { indicator in
                GridRow {
                    Text(indicator.title).font(.callout)
                    Toggle("", isOn: binding(indicator, keyPath: \.enabledIndicators)).labelsHidden()
                    Toggle("", isOn: binding(indicator, keyPath: \.barIndicators)).labelsHidden()
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(_ indicator: Indicator, keyPath: ReferenceWritableKeyPath<AppSettings, Set<Indicator>>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath].contains(indicator) },
            set: { on in
                if on { settings[keyPath: keyPath].insert(indicator) } else { settings[keyPath: keyPath].remove(indicator) }
            }
        )
    }
}

enum NoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func name(forFrequency f: Double) -> String {
        guard f > 0 else { return "" }
        let midi = Int((69 + 12 * log2(f / 440)).rounded())
        let octave = midi / 12 - 1
        return "\(names[((midi % 12) + 12) % 12])\(octave)"
    }
}
