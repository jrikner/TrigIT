# Native Swift app for macOS only

TrigIT is a native Swift app built on Apple's audio and MIDI frameworks, not a cross-platform stack such as JUCE or Electron. The app runs show-critical timing on a Mac, so we chose the smallest runtime, the most direct access to audio input for LTC, and the network MIDI built into macOS, and gave up running on Windows.
