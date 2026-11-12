import AVFoundation
import Foundation
import Observation
import Speech

enum VoiceError: LocalizedError {
    case microphone, recording, noTranscript, unsupported, speechPermission
    var errorDescription: String? {
        switch self {
        case .microphone: String(localized: "请允许「逐日」使用麦克风。")
        case .recording: String(localized: "麦克风暂不可用，请重试或输入文字。")
        case .noTranscript: String(localized: "没有听清，请再试一次或输入文字。")
        case .unsupported: String(localized: "设备上的语音模型暂不可用，可以使用键盘听写。")
        case .speechPermission: String(localized: "请允许「逐日」使用语音识别，或使用键盘听写。")
        }
    }
}

@MainActor
@Observable
final class VoiceCapture {
    private var recorder: AVAudioRecorder?
    private(set) var recording = false
    private(set) var processing = false
    /// When the current recording started (for the elapsed time shown while listening).
    private(set) var startedAt: Date?

    /// The voice's loudness right now, 0…1 (for the bars that move while listening).
    func level() -> Double {
        guard let recorder, recording else { return 0 }
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))
        return max(0, min(1, (power + 52) / 44))
    }

    func start() async throws {
        guard !recording, !processing else { return }
        processing = true
        defer { processing = false }
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceError.microphone }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("asmo-\(UUID()).caf")
        do {
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw VoiceError.recording }
            self.recorder = recorder
            startedAt = .now
            recording = true
        } catch {
            try? FileManager.default.removeItem(at: file)
            releaseAudioSession()
            throw error
        }
    }

    func finish(locale: Locale) async throws -> String {
        guard let recorder else { throw VoiceError.recording }
        let file = recorder.url
        recorder.stop()
        releaseAudioSession()
        self.recorder = nil
        recording = false
        startedAt = nil
        processing = true
        defer {
            processing = false
            try? FileManager.default.removeItem(at: file)
        }
        if #available(iOS 26, macOS 26, *), SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           let transcript = try? await Self.modernTranscript(file: file, locale: supported),
           !transcript.trimmed.isEmpty {
            return transcript.trimmed
        }
        return try await legacyTranscript(file: file, locale: locale)
    }

    /// Transcribes an existing audio file with the same on-device path as live dictation.
    static func transcribe(file: URL, locale: Locale) async throws -> String {
        if #available(iOS 26, macOS 26, *), SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           let transcript = try? await modernTranscript(file: file, locale: supported),
           !transcript.trimmed.isEmpty {
            return transcript.trimmed
        }
        return try await VoiceCapture().legacyTranscript(file: file, locale: locale)
    }

    /// Words to listen for, taken from the user's own items (English words and names).
    nonisolated(unsafe) static var vocabulary: [String] = []

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        try? FileManager.default.removeItem(at: recorder.url)
        self.recorder = nil
        recording = false
        startedAt = nil
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    @available(iOS 26, macOS 26, *)
    private static func modernTranscript(file: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        if let install = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        let audio = try AVAudioFile(forReading: file)
        async let transcript: String = {
            var result = ""
            for try await part in transcriber.results where part.isFinal {
                let next = String(part.text.characters)
                if !result.isEmpty && !result.hasSuffix(" ") && !next.hasPrefix(" ") {
                    result += " "
                }
                result += next
            }
            return result
        }()
        do {
            try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
            return try await transcript
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// The older on-device recognizer only handles about a minute and silently drops the rest, so long recordings
    /// are cut into pieces under 45 s, each cut at the quietest moment near the boundary, and joined.
    private func legacyTranscript(file: URL, locale: Locale) async throws -> String {
        let pieces = (try? Self.split(file, maxSeconds: 45)) ?? [file]
        guard pieces.count > 1 else { return try await legacyPiece(file: file, locale: locale) }
        defer { pieces.forEach { try? FileManager.default.removeItem(at: $0) } }
        var parts: [String] = []
        for piece in pieces {
            if let text = try? await legacyPiece(file: piece, locale: locale), !text.trimmed.isEmpty { parts.append(text.trimmed) }
        }
        guard !parts.isEmpty else { throw VoiceError.noTranscript }
        return parts.joined(separator: "，")
    }

    static func split(_ file: URL, maxSeconds: Double) throws -> [URL] {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let rate = format.sampleRate
        let total = AVAudioFrameCount(audio.length)
        guard Double(total) / rate > maxSeconds,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return [file] }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [file] }
        let window = Int(rate * 0.05)
        func energy(at frame: Int) -> Float {
            var sum: Float = 0
            let end = min(Int(total), frame + window)
            guard frame < end else { return .greatestFiniteMagnitude }
            for index in frame..<end { sum += channel[index] * channel[index] }
            return sum / Float(end - frame)
        }
        var cuts: [Int] = [0]
        var start = 0
        let maxFrames = Int(rate * maxSeconds)
        while Int(total) - start > maxFrames {
            // Look for the quietest 50 ms in the last 8 s before the limit.
            let searchEnd = start + maxFrames
            var best = searchEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var frame = max(start + Int(rate * 5), searchEnd - Int(rate * 8))
            while frame < searchEnd {
                let value = energy(at: frame)
                if value < bestEnergy { bestEnergy = value; best = frame }
                frame += window
            }
            cuts.append(best)
            start = best
        }
        cuts.append(Int(total))
        var urls: [URL] = []
        for index in 0..<(cuts.count - 1) {
            let length = AVAudioFrameCount(cuts[index + 1] - cuts[index])
            guard length > 0, let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { continue }
            part.frameLength = length
            for channelIndex in 0..<Int(format.channelCount) {
                if let source = buffer.floatChannelData?[channelIndex], let target = part.floatChannelData?[channelIndex] {
                    target.update(from: source.advanced(by: cuts[index]), count: Int(length))
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("asmo-piece-\(UUID()).caf")
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: part)
            urls.append(url)
        }
        return urls
    }

    private func legacyPiece(file: URL, locale: Locale) async throws -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw VoiceError.speechPermission }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw VoiceError.unsupported }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        // Names and English words the user actually writes (rebuttal, Wise, Kyoto…) help mixed speech.
        request.contextualStrings = Array(VoiceCapture.vocabulary.prefix(100))
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let state = RecognitionCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation, recognizer: recognizer, request: request)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }
}

private final class RecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, any Error>?
    private var finished = false

    func begin(_ continuation: CheckedContinuation<String, any Error>, recognizer: SFSpeechRecognizer,
               request: SFSpeechRecognitionRequest) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString.trimmed
                self.finish(text.isEmpty ? .failure(VoiceError.noTranscript) : .success(text))
            } else if let error {
                self.finish(.failure(error))
            }
        }
        lock.lock()
        if finished { lock.unlock(); task.cancel() }
        else { self.task = task; lock.unlock() }
    }

    func finish(_ result: Result<String, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
