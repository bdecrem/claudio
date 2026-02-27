import Foundation
import Speech
import AVFoundation

@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isListening = false
    var isAuthorized = false
    var audioLevel: Float = 0

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 2.0

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isAuthorized = (status == .authorized)
            }
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    self?.isAuthorized = false
                }
            }
        }
    }

    func startListening() {
        guard let recognizer, recognizer.isAvailable else { return }

        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        #endif

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.updateAudioLevel(buffer: buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.transcript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopEngine()
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            transcript = ""
            resetSilenceTimer()
        } catch {
            stopEngine()
        }
    }

    func stopListening() -> String {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopEngine()
        let result = transcript
        return result
    }

    private func stopEngine() {
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
            self?.audioLevel = 0
        }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

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

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isListening else { return }
            _ = self.stopListening()
        }
    }
}
