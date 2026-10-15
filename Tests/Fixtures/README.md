# Test fixtures

Reference material for the tolerance tests in `PraatFixtureTests`. None of
it is anyone's private voice.

## librispeech-198-209-0000-excerpt

- `librispeech-198-209-0000-excerpt.wav`: 4.0 s of read speech, 16 kHz,
  16-bit mono. Seconds 0.5 to 4.5 of LibriSpeech utterance 198-209-0000:
  *Sense and Sensibility*, chapter 18, by Jane Austen, read by Heather
  Barnett for LibriVox. From the LibriSpeech corpus (SLR12,
  <https://www.openslr.org/12/>), obtained through the librosa example data
  set. Licence: CC BY 4.0 (<https://creativecommons.org/licenses/by/4.0/>).
- `librispeech-198-209-0000-excerpt.praat.json`: Praat's formant track for
  the excerpt, produced offline with praat-parselmouth 0.4.7 (Praat 6.1.38)
  using `To Formant (burg)` with time step 0.01 s, 5 formants, ceiling
  5500 Hz, window 0.025 s, pre-emphasis from 50 Hz, plus `To Pitch (ac)`
  (60 to 600 Hz) for voicing. Each frame holds the time, the pitch (null
  when unvoiced) and `[frequency, bandwidth]` for F1 to F3.

Praat is used only offline for fixtures like this; the app never depends on
it at run time.
