import SwiftUI
import AVFoundation
import Speech

@main
struct ClaudioApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}

private struct DemoRootView: View {
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                SpeechAnalyzerDemoView()
            } else {
                VStack(spacing: 12) {
                    Text("SpeechAnalyzer Demo")
                        .font(.title2.weight(.semibold))
                    Text("Requires iOS 26+ runtime.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }
}

@available(iOS 26.0, *)
private struct SpeechAnalyzerDemoView: View {
    @State private var service = SpeechAnalyzerDemoService()

    var body: some View {
        VStack(spacing: 16) {
            Text("SpeechAnalyzer Demo")
                .font(.title2.weight(.semibold))

            Text(service.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(service.transcript.isEmpty ? "Transcript will appear here..." : service.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let error = service.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(service.isRunning ? "Stop" : "Start Listening") {
                if service.isRunning {
                    service.stop()
                } else {
                    service.start()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

@available(iOS 26.0, *)
@Observable
private final class SpeechAnalyzerDemoService {
    var transcript = ""
    var status = "Idle"
    var isRunning = false
    var errorMessage: String?

    private var audioEngine = AVAudioEngine()
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    private var analyzer: SpeechAnalyzer?
    private var usingDictation = false

    @MainActor
    func start() {
        guard !isRunning else { return }
        transcript = ""
        errorMessage = nil
        status = "Requesting microphone permission..."

        analyzerTask = Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestMicrophonePermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "Microphone permission denied."
                    self.status = "Permission denied"
                }
                return
            }

            do {
                try await self.startPipeline()
                await MainActor.run {
                    self.isRunning = true
                    let mode = self.usingDictation ? "dictation" : "speech"
                    self.status = "Listening (\(mode))... speak now"
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.status = "Failed to start"
                }
            }
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }

        status = "Stopping..."
        isRunning = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        inputContinuation?.finish()
        inputContinuation = nil

        resultsTask?.cancel()
        resultsTask = nil

        analyzerTask?.cancel()
        analyzerTask = nil

        Task { [weak self] in
            try? await self?.analyzer?.finalizeAndFinishThroughEndOfInput()
            await MainActor.run { self?.status = "Stopped" }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        let current = AVAudioApplication.shared.recordPermission
        switch current {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func startPipeline() async throws {
        // Configure audio session BEFORE accessing inputNode format —
        // the Simulator returns a zero-format otherwise.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "SpeechAnalyzerDemo", code: 4, userInfo: [NSLocalizedDescriptionKey: "No valid audio input available. Check microphone access."])
        }

        // Try SpeechTranscriber first, fall back to DictationTranscriber
        // (Simulator often lacks the on-device speech model)
        let currentLocale = Locale.current
        let speechLocales = await SpeechTranscriber.supportedLocales
        let dictationLocales = await DictationTranscriber.supportedLocales
        print("[SpeechDemo] Current locale: \(currentLocale.identifier)")
        print("[SpeechDemo] SpeechTranscriber supportedLocales: \(speechLocales.map(\.identifier))")
        print("[SpeechDemo] DictationTranscriber supportedLocales: \(dictationLocales.map(\.identifier))")

        let module: any LocaleDependentSpeechModule
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: currentLocale) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            usingDictation = false

            resultsTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriber.results {
                        await MainActor.run {
                            self.transcript = String(describing: result.text)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.status = "Transcription error"
                    }
                }
            }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: currentLocale) {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            module = transcriber
            usingDictation = true

            resultsTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriber.results {
                        await MainActor.run {
                            self.transcript = String(describing: result.text)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.status = "Transcription error"
                    }
                }
            }
        } else {
            throw NSError(domain: "SpeechAnalyzerDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Current locale not supported by any available transcriber."])
        }

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: inputFormat
        ) ?? inputFormat

        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer

        let stream = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = stream.continuation

        try configureAudioEngine(targetFormat: analyzerFormat, inputFormat: inputFormat)
        try await analyzer.start(inputSequence: stream.stream)
    }

    private func configureAudioEngine(targetFormat: AVAudioFormat, inputFormat: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let continuation = self.inputContinuation else { return }
            do {
                let converted = try self.convertIfNeeded(buffer, to: targetFormat)
                continuation.yield(AnalyzerInput(buffer: converted))
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.status = "Audio conversion error"
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw NSError(domain: "SpeechAnalyzerDemo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."])
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw NSError(domain: "SpeechAnalyzerDemo", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output buffer."])
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)

        if let conversionError { throw conversionError }
        return outBuffer
    }
}
