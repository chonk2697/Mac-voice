# MVP decisions

Status of the design questions for the first version. Numbers match the
original question list. "Decided" items came from Zoe; "Default" items are
assumptions that stand unless overridden; "Open" items are still being
discussed.

## Toolchain and project setup

1. **Xcode.** Decided: SwiftPM-first, with Xcode available. Xcode 27.0
   (Swift 6.4, macOS 27.0 SDK) is installed and its first-launch setup is
   done; the Command Line Tools (Swift 6.3.3, macOS 26.5 SDK) are also
   present. The project is a `Package.swift` that builds with the CLT alone
   plus a script that assembles the `.app` bundle, so contributors do not need
   Xcode. Xcode opens the package directly and adds previews, Instruments,
   asset catalogs and Core ML compilation; a thin Xcode app target can be
   added later if wanted. Pending: `sudo xcode-select -s /Applications/Xcode.app`
   so the shell uses Xcode's toolchain; until then build commands set
   `DEVELOPER_DIR` explicitly.
2. **Platform.** Default: macOS 26 minimum, compiled against the macOS 27 SDK
   with availability checks for anything newer. This Mac runs 26.7.1; macOS 27
   exists (Xcode 27 ships only its SDK). Raise the minimum to 27 if the Mac is
   upgraded.
3. **Name.** Default: working name "Voice", bundle id placeholder
   `com.zoezyla.voice`.
4. **Layout.** Default: one Swift package with a UI-free `VoiceAnalysis`
   library target, the menu bar app target, a small CLI that runs the same
   analysis over WAV files, and a test target.
5. **Libraries.** Decided after research: no runtime dependencies beyond
   Apple frameworks (AVAudioEngine, Accelerate, SwiftUI, AppKit).
   - Pitch: own YIN / McLeod implementation now; a seam for a Core ML neural
     tracker (SwiftF0 is the current best in public benchmarks) later.
   - Formants: own Burg LPC following Praat's method (pre-emphasis, Gaussian
     window, order = 2 x max formants, root finding, bandwidth filter,
     tracking across frames).
   - Weight / brightness: computed from the FFT and the pitch estimate.
   - Praat (via `parselmouth`) is used offline as the oracle for test
     fixtures, never at runtime.
6. **Distribution.** Decided: none. Personal use and source builds only.
   Ad-hoc code signing, no App Sandbox, no notarization.
7. **Remote and CI.** Default: local only for now. Open: GitHub remote and a
   Buildkite pipeline later.
8. **Test material.** Default: synthesized vowels (source-filter model) for
   unit tests now; real clips later, kept out of the repo.

## Indicators

9. **Framework.** Decided: the pitch / resonance / weight model
   (TransVoiceLessons vocabulary). Other framings can feed later versions.
10. **Pitch.** Default: Hz in the bar, note name in the panel, speech search
    range 60 to 600 Hz.
11. **Formants.** Decided after measurement: F1 to F3 from Burg LPC in
    Praat's recipe, assigned to tracks by a fixed-lag Viterbi tracker, median
    over voiced frames, blank when silent. Vowel-specific exercise mode later.
    - Reference: Praat's `To Formant (burg)` (time step 0.01 s, 5 formants,
      ceiling 5500 Hz, window 0.025 s, pre-emphasis from 50 Hz) run offline
      through praat-parselmouth in a scratch Python environment outside the
      repo. Comparison is per 100 ms bin of Praat-voiced frames, medians of
      both tracks, errors relative to Praat. `voice-cli analyze --frames` and
      `voice-cli candidates` dump what the app computes, `voice-cli record`
      makes 16 kHz clips; clips live in `recordings/`, which is git-ignored.
    - Front end, measured on two CC BY LibriSpeech clips (a female reader at
      about 215 Hz and a male reader at about 77 Hz): the second pre-emphasis
      pass at the input rate, added earlier for breathy voices, cost most of
      F1 on real speech (a candidate within 10 % of Praat's F1 existed in only
      16 % of voiced frames, 94 % with a single pass). A 35 to 40 ms Gaussian
      window beat both the 30 ms one and Praat's 50 ms; an 11 kHz analysis
      rate (Praat's 5.5 kHz ceiling) beat the 10.67 kHz one. Settings now:
      single pre-emphasis at the analysis rate, 40 ms window, 11 kHz, order
      10, no bandwidth cutoff before tracking. Candidate recall within 10 %
      of Praat on the female clip: F1 96 %, F2 96 %, F3 97 %.
    - Tracker (`FormantTracker`): per frame, every assignment of candidates
      to F1 to F3 in increasing order, including empty slots, is a state.
      Local cost: 0.25 per natural-log unit from reference frequencies
      560 / 1680 / 2800 Hz, 10 per log unit outside the plausible ranges
      150-1100 / 500-3200 / 1700-4000 Hz, 3 per empty slot, and 6 for passing
      over a candidate below the highest chosen one, scaled to nothing at a
      1000 Hz bandwidth. Transition cost: 1 per octave a slot moves, 0.5 for
      a slot that appears or disappears. Lookahead 5 frames (100 ms), so
      voiced frames leave the analyzer 100 ms late. A grid search against
      Praat chose the weights; the clearest result was that bandwidth should
      not be charged for directly, only through the skip rule, because Praat
      reports the lowest poles whatever their width.
    - Results, medians over voiced 100 ms bins (error relative to Praat,
      median |error|, fraction of bins off by more than 20 %, coverage of
      Praat-voiced bins):

      | clip | formant | before | after |
      |---|---|---|---|
      | female 198-209-0000 | F1 | +25.5 %, 25.5 %, 62 %, 68 % | -0.8 %, 3.8 %, 15 %, 90 % |
      | | F2 | +3.7 %, 5.0 %, 27 % | -1.1 %, 2.7 %, 10 % |
      | | F3 | +10.3 %, 10.3 %, 30 % | -0.4 %, 2.2 %, 1 % |
      | | F3 above 3.8 kHz | 30 % of frames | 0.3 % of frames |
      | male 5703-47212-0000 (Praat ceiling 5000) | F1 | +62.7 %, 62.7 %, 89 %, 27 % | +1.2 %, 6.3 %, 19 %, 78 % |
      | | F2 | +72.2 %, 72.2 %, 68 % | +2.3 %, 3.6 %, 9 % |
      | | F3 | +58.2 %, 58.2 %, 86 % | +1.9 %, 2.3 %, 13 % |

      Zoe's own clips: pending her recordings (see the session notes).
    - Ceiling: a pitch- or tract-length-following ceiling (Praat's 5000 Hz
      for low voices) was considered and not adopted: with the fixed 5.5 kHz
      ceiling the male clip's medians land within 2.5 % of Praat at 5000 Hz,
      while Praat's own answers at 5000 and 5500 Hz differ by 15 % on that
      clip, so the ceiling is below the noise of the reference. Revisit if a
      low voice shows a bias.
    - Known limit, shared with Praat: a very breathy vowel at a high pitch (a
      wide F1 and a steep source, around 160 Hz and above) yields a source
      pole below F1 as the lowest candidate, and both report it as F1. The
      double pre-emphasis that hid this on synthetic vowels is what broke F1
      on real speech, so it stays off.
    - Tests: tracker unit tests on hand-built candidate sequences, an
      analyzer test on a synthesized /a/ to /i/ glide, and a tolerance test
      against Praat's track for a CC BY LibriSpeech excerpt in
      `Tests/Fixtures` (medians within 6 %, median |error| under 8 %, gross
      errors under 25 %, F3 above 3.8 kHz in under 5 % of frames).
12. **Resonance.** Decided: both readouts.
    - A vocal-tract-size gauge estimated from formant spacing (the
      scale-invariant method in Anikin, Barreda and Reby 2023), calibrated
      between typical masculine and feminine tract lengths.
    - Formant shift relative to a recorded baseline.
    - Consequence: baseline recording moves into the MVP (see 16).
13. **Weight.** Default: H1 minus H2 with formant correction (H1* minus H2*),
    shown as a light-to-heavy gauge. Lower values mean heavier. The same
    measure appears in other tools as "softness" with the sign flipped.
14. **Brightness.** Decided: experimental trend. Measured as the alpha ratio
    (level of the 1 to 5 kHz band minus the 50 Hz to 1 kHz band, in dB), a
    standard voice measure; higher is brighter. A plain spectral centroid was
    tried first and rejected because the fundamental dominates it, so it
    mostly tracked pitch. Shown as its raw value and, once a baseline exists,
    as the change against the baseline. Marked experimental in the panel; it
    responds to resonance, weight and twang together, so it may prove
    redundant.
15. **Targets.** Default: presets (feminine, masculine, androgynous) plus
    custom ranges; in-range colouring; numbers always visible.
16. **Baseline.** Decided via 12: in the MVP. Record roughly ten seconds of
    ordinary speech; keep summary statistics only, never the audio.
17. **Responsiveness and history.** Decided: more live, plus graphs.
    - Smoothing 150 ms, bar refresh about 15 times per second.
    - The panel shows a scrolling timeline per enabled indicator with 30 s,
      2 min and 10 min windows, kept in memory only.
    - A drift readout compares the last ten seconds with the session so far,
      to show gradual degradation while speaking.

## Menu bar experience

18. **Location.** Default: menu bar status item.
19. **Click.** Default: click opens a panel with gauges, graphs and toggles;
    the bar shows a compact summary of the enabled indicators.
20. **Bar content.** Default: text for pitch, small gauges for the rest; the
    user picks which indicators appear in the bar.
21. **Width.** This Mac is a MacBook Pro with a notch; bar width budget
    about 140 pt.
22. **Silence.** Decided: dim readouts when no voice; auto-idle after a period
    of silence, with only a cheap level check running so it resumes by itself;
    toggle and delay in settings. Default delay 2 min.
23. **Input device.** Default: system default input, with a picker.
24. **Extra window.** Superseded by 17: graphs live in the panel; a detachable
    window can come later.
25. **History.** Default: nothing persisted except the baseline summary and
    settings. Session graphs are in memory.
26. **Other.** Default: launch-at-login toggle, VoiceOver labels on gauges,
    English only, no audible feedback.
