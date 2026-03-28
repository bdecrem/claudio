import Foundation
import Speech
import AVFoundation

@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isListening = false
    var isAuthorized = false
    var audioLevel: Float = 0

    private var audioEngine = AVAudioEngine()
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 2.0

    // Type-erased bridges for iOS 26+ SpeechAnalyzer pipeline cleanup.
    // These closures capture the typed SpeechAnalyzer/AsyncStream objects
    // so that stopPipeline() doesn't need @available annotations.
    private var finishContinuation: (() -> Void)?
    private var finalizeAnalyzer: (() async throws -> Void)?

    func requestAuthorization() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    func startListening() {
        guard !isListening else { return }

        if #available(iOS 26.0, *) {
            isListening = true
            transcript = ""
            audioLevel = 0

            analyzerTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.startPipeline()
                } catch {
                    await MainActor.run {
                        self.isListening = false
                        self.audioLevel = 0
                    }
                }
            }
        }
    }

    func stopListening() -> String {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopPipeline()
        let result = transcript
        return result
    }

    // MARK: - iOS 26+ SpeechAnalyzer Pipeline
    // Follows the exact patterns from SpeechAnalyzerDemoApp/ClaudioApp.swift

    @available(iOS 26.0, *)
    private func startPipeline() async throws {
        // 1. Resolve supported locale
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Current locale not supported."])
        }

        // 2. Create transcriber with progressive transcription
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // 3. Negotiate audio format
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) ?? inputFormat

        // 4. Create analyzer with transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 5. AsyncStream bridge: mic buffers → analyzer input
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        finishContinuation = { stream.continuation.finish() }
        finalizeAnalyzer = { try await analyzer.finalizeAndFinishThroughEndOfInput() }

        // 6. Consume transcription results via AsyncSequence
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await MainActor.run {
                        self.transcript = String(describing: result.text)
                        self.resetSilenceTimer()
                    }
                }
            } catch {
                // Transcription stream ended
            }
        }

        // 7. Configure audio engine and start capturing
        try configureAudioEngine(targetFormat: analyzerFormat, continuation: stream.continuation)

        // 8. Start initial silence timer (auto-stop after 2s of no results)
        await MainActor.run {
            self.resetSilenceTimer()
        }

        // 9. Start analyzer — blocks until stream ends or cancelled
        try await analyzer.start(inputSequence: stream.stream)
    }

    @available(iOS 26.0, *)
    private func configureAudioEngine(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(buffer: buffer)
            do {
                let converted = try self.convertIfNeeded(buffer, to: targetFormat)
                continuation.yield(AnalyzerInput(buffer: converted))
            } catch {
                // Audio conversion error — skip this buffer
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Pipeline Teardown
    // No @available needed — uses type-erased closures for iOS 26+ cleanup

    private func stopPipeline() {
        isListening = false
        audioLevel = 0

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        finishContinuation?()
        finishContinuation = nil

        resultsTask?.cancel()
        resultsTask = nil

        analyzerTask?.cancel()
        analyzerTask = nil

        let finalize = finalizeAnalyzer
        finalizeAnalyzer = nil
        Task {
            try? await finalize?()
        }
    }

    // MARK: - Audio Level

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(frames)
        let level = min(max(avg * 10, 0), 1)
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isListening else { return }
            _ = self.stopListening()
        }
    }

    // MARK: - Audio Format Conversion

    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw NSError(domain: "SpeechRecognizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."])
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw NSError(domain: "SpeechRecognizer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output buffer."])
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
