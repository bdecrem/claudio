# SpeechAnalyzer Demo (iOS 26+)

This folder contains a standalone Xcode iPhone app that demonstrates Apple's new Speech framework pipeline for live transcription on iOS 26+.

## What is new vs the old API

Older approach (what many apps used before):
- `SFSpeechRecognizer`
- `SFSpeechAudioBufferRecognitionRequest`
- Callback-based recognition task (`recognitionTask(with:)`)

New iOS 26 approach used here:
- `SpeechAnalyzer` (session coordinator)
- `SpeechTranscriber` (transcription module)
- `AnalyzerInput` (audio buffers fed into the analyzer)
- `AsyncSequence` results (`for try await result in transcriber.results`)

In short: the new API is module-based, async/await-native, and built around a speech analysis pipeline.

## Demo location

- Project: `SpeechAnalyzerDemoApp/Claudio.xcodeproj`
- Main code: `SpeechAnalyzerDemoApp/Claudio/ClaudioApp.swift`

## How this demo works

The demo keeps everything in one file (`ClaudioApp.swift`) for simplicity.

### 1. UI layer
`SpeechAnalyzerDemoView` shows:
- Status text (`Idle`, `Listening`, errors)
- Live transcript text area
- One button: `Start Listening` / `Stop`

### 2. Service layer
`SpeechAnalyzerDemoService` handles microphone + transcription state.

Key state:
- `transcript`: live text shown in UI
- `status`: current phase
- `isRunning`: recording/transcribing on/off
- `errorMessage`: error display

Core components:
- `AVAudioEngine` for mic capture
- `SpeechTranscriber` for transcription
- `SpeechAnalyzer` to process audio
- `AsyncStream<AnalyzerInput>` to bridge mic buffers into analyzer input

### 3. Start flow
When user taps Start:
1. Request microphone permission (`AVAudioApplication.requestRecordPermission`)
2. Resolve supported locale (`SpeechTranscriber.supportedLocale(equivalentTo:)`)
3. Create transcriber:
   - `SpeechTranscriber(locale: ..., preset: .progressiveTranscription)`
4. Query best analyzer-compatible format:
   - `SpeechAnalyzer.bestAvailableAudioFormat(...)`
5. Create analyzer with modules:
   - `SpeechAnalyzer(modules: [transcriber])`
6. Start a task to consume results:
   - `for try await result in transcriber.results { ... }`
7. Start `AVAudioEngine` input tap and feed buffers as `AnalyzerInput`
8. Start analyzer with stream:
   - `try await analyzer.start(inputSequence: stream.stream)`

### 4. Stop flow
When user taps Stop:
1. Stop `AVAudioEngine`
2. Remove input tap
3. Finish `AsyncStream` continuation
4. Cancel tasks
5. Finalize and finish analyzer:
   - `finalizeAndFinishThroughEndOfInput()`

## Availability

- Demo uses `@available(iOS 26.0, *)` for the new API.
- On older runtimes, UI shows a simple "Requires iOS 26+ runtime" message.

## How to run

1. Open `SpeechAnalyzerDemoApp/Claudio.xcodeproj`
2. Select an iOS 26 simulator
3. Run app
4. Allow microphone permission
5. In Simulator, set audio input to your Mac mic (`I/O -> Audio Input`)
6. Tap `Start Listening` and speak

## Notes

- This is intentionally minimal and not production-hardened.
- No asset/model pre-install UI is included.
- No punctuation/vad tuning/custom context is included.
- Everything is in one file by design for quick API exploration.
