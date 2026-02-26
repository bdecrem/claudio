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
    private var transcriber: SpeechTranscriber?

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
                    self.status = "Listening... speak now"
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
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startPipeline() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw NSError(domain: "SpeechAnalyzerDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Current locale not supported."])
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) ?? inputFormat

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let stream = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = stream.continuation

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

        try configureAudioEngine(targetFormat: analyzerFormat)
        try await analyzer.start(inputSequence: stream.stream)
    }

    private func configureAudioEngine(targetFormat: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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
