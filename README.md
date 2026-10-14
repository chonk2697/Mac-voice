# Voice

A macOS menu bar app for real-time voice feedback during voice training
(feminizing, masculinizing, or neutral). It listens to the microphone and shows
key indicators of the voice — pitch, formants, resonance, vocal weight, and
brightness — in the menu bar, so adjustments can be made while speaking.

Clicking the menu bar item toggles which indicators are shown.

## Status

Pre-MVP. Design decisions are still being settled; see the conversation and
upcoming docs for the open questions.

## Principles

- Audio is processed on-device and never stored or transmitted.
- Targets the current macOS release only; no legacy support.
- Low CPU and memory footprint so it can stay open all day.
