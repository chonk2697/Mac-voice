# Voice

A macOS menu bar app for real-time voice feedback during voice training
(feminizing, masculinizing, or neutral). It listens to the microphone and shows
key indicators of the voice in the menu bar, so adjustments can be made while
speaking. Clicking the menu bar item opens a panel with gauges, scrolling
history and toggles for each indicator.

Everything is processed on-device. No audio is stored or sent anywhere; the
only thing kept between launches is your settings and, if you record one, the
summary numbers of your baseline.

## Indicators

| Indicator | What is measured | How |
|---|---|---|
| Pitch | Fundamental frequency in Hz, with the note name | YIN (de Cheveigné & Kawahara 2002) on 16 kHz audio |
| Formants | F1, F2, F3 in Hz | Burg LPC at a 5.3 kHz ceiling, Praat's recipe |
| Resonance | Vocal tract size, 0 dark to 100 bright, plus formant shift against your baseline | Vocal tract length from formant spacing (Anikin, Barreda & Reby 2023) |
| Weight | Vocal fold mass, 0 light to 100 heavy | H1*-H2*: first minus second harmonic level, corrected for F1 and F2 (Iseli & Alwan 2004) |
| Brightness | Experimental. Upper-band energy in dB and its change against your baseline | Alpha ratio: 1 to 5 kHz level minus 50 Hz to 1 kHz level |

Target presets (feminine, masculine, androgynous, custom) colour the menu bar
readout green or orange. The ranges are starting points drawn from published
speaking-voice figures, not clinical targets, and the gauge anchors can be
changed in Settings.

The panel also shows drift, the median of the last ten seconds against the
session, and a timeline per indicator over the last 30 seconds, 2 minutes or
10 minutes, so gradual changes while speaking are visible.

## Building

Requires macOS 26 and either Xcode 27 or just the Command Line Tools. There
are no third-party dependencies.

```bash
swift test              # analysis library tests
scripts/run.sh          # build build/Voice.app and launch it
```

`scripts/bundle.sh` assembles the app bundle from the SwiftPM build; the
first launch asks for microphone access. The package also opens directly in
Xcode (`open Package.swift`).

The same analysis runs from the command line over audio files:

```bash
swift run voice-cli analyze recording.wav
swift run voice-cli synth vowel.wav --f0 180 --vowel feminineAh --tilt 12
```

## Layout

- `Sources/VoiceAnalysis` — the signal processing: pitch, resampling, LPC and
  formants, spectrum and harmonic measures, vocal tract length, the per-hop
  analyzer, smoothing, timelines, baseline and session state. Pure Swift on
  Accelerate, no UI, fully unit-tested with synthesized vowels.
- `Sources/VoiceApp` — the menu bar app: microphone capture, the main-actor
  monitor model, the status item, the SwiftUI panel and settings.
- `Sources/VoiceCLI` — `voice-cli`.
- `docs/decisions.md` — the design decisions behind the MVP.

## Status

MVP. The measurements are validated against synthesized vowels; real-voice
calibration of the gauge anchors and target bands is the next step.
