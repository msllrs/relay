import AVFoundation
import CoreAudio
import Foundation
import Speech
import Synchronization

/// Apple's SpeechAnalyzer/SpeechTranscriber engine (macOS 26+): on-device,
/// streaming, with volatile partial results — the successor to
/// SFSpeechRecognizer without its 1-minute session folklore.
final class SpeechAnalyzerEngine: SpeechEngine, @unchecked Sendable {
    private var capture: (any AudioCaptureSource)?
    private var isRecordingFlag = false
    private let finalizedText = Mutex("")

    @available(macOS 26.0, *)
    private final class Session: @unchecked Sendable {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        var resultsTask: Task<Void, Never>?
        let analyzerFormat: AVAudioFormat?
        /// Confined to the capture source's processing queue.
        var converter: AVAudioConverter?

        init(
            transcriber: SpeechTranscriber,
            analyzer: SpeechAnalyzer,
            inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
            analyzerFormat: AVAudioFormat?
        ) {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.analyzerFormat = analyzerFormat
        }
    }

    private var sessionBox: AnyObject?
    private var prepared = false

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var isAvailable: Bool { Self.isSupported }
    var needsModelDownload: Bool { !prepared }
    var handlesPermissionInternally: Bool { false }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else {
            throw SpeechEngineError.engineUnavailable
        }
        progress(0.05)
        let locale = Locale.current
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SpeechEngineError.transcriptionFailed("SpeechAnalyzer doesn't support \(locale.identifier)")
        }

        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let downloadProgress = request.progress
                let progressTask = Task {
                    while !Task.isCancelled, !downloadProgress.isFinished {
                        progress(max(0.05, downloadProgress.fractionCompleted * 0.9))
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                defer { progressTask.cancel() }
                try await request.downloadAndInstall()
            }
        }
        prepared = true
        progress(1.0)
    }

    func startStreaming(
        inputDeviceID: AudioDeviceID?,
        onPartialResult: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw SpeechEngineError.engineUnavailable
        }
        guard prepared else {
            throw SpeechEngineError.engineUnavailable
        }

        finalizedText.withLock { $0 = "" }
        isRecordingFlag = true

        let transcriber = SpeechTranscriber(
            locale: .current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        let session = Session(
            transcriber: transcriber,
            analyzer: analyzer,
            inputContinuation: inputContinuation,
            analyzerFormat: analyzerFormat
        )
        sessionBox = session

        // Collect results: finals accumulate, volatiles ride on top as the
        // live partial the UI displays.
        session.resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let combined = self.finalizedText.withLock { current -> String in
                            if !text.isEmpty {
                                current = current.isEmpty ? text : current + " " + text
                            }
                            return current
                        }
                        onPartialResult(combined)
                    } else if !text.isEmpty {
                        let base = self.finalizedText.withLock { $0 }
                        onPartialResult(base.isEmpty ? text : base + " " + text)
                    }
                }
            } catch {
                NSLog("SpeechAnalyzerEngine: results stream error: %@", error.localizedDescription)
            }
        }

        try await analyzer.start(inputSequence: inputStream)

        // Warm-capture pre-roll: audio from just before the hotkey landed.
        if let preRollBuffer = PCM16kMonoConverter.makeBuffer(from: PreRollAudioService.shared.drainPreRoll()) {
            feed(preRollBuffer, into: session)
        }

        let captureSource = AudioCaptureSourceFactory.make()
        self.capture = captureSource
        try captureSource.start(deviceID: inputDeviceID, onBuffer: { [weak self] buffer in
            guard let self, self.isRecordingFlag else { return }
            self.feed(buffer, into: session)
        }, onLevel: onAudioLevel)
    }

    @available(macOS 26.0, *)
    private func feed(_ buffer: AVAudioPCMBuffer, into session: Session) {
        var toSend = buffer
        if let format = session.analyzerFormat, format != buffer.format {
            if session.converter == nil || session.converter?.inputFormat != buffer.format {
                session.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            if let converter = session.converter {
                let ratio = format.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(max(1, (Double(buffer.frameLength) * ratio).rounded(.up) + 32))
                if let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) {
                    nonisolated(unsafe) var consumed = false
                    nonisolated(unsafe) let input = buffer
                    var error: NSError?
                    converter.convert(to: output, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return input
                    }
                    if output.frameLength > 0 {
                        toSend = output
                    }
                }
            }
        }
        session.inputContinuation.yield(AnalyzerInput(buffer: toSend))
    }

    func stopAndTranscribe() async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw SpeechEngineError.engineUnavailable
        }
        isRecordingFlag = false
        capture?.stop()
        capture = nil

        guard let session = sessionBox as? Session else {
            return finalizedText.withLock { $0 }
        }
        sessionBox = nil

        session.inputContinuation.finish()
        do {
            try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("SpeechAnalyzerEngine: finalize error: %@", error.localizedDescription)
        }
        await session.resultsTask?.value

        return finalizedText.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        isRecordingFlag = false
        capture?.stop()
        capture = nil
        if #available(macOS 26.0, *), let session = sessionBox as? Session {
            session.inputContinuation.finish()
            session.resultsTask?.cancel()
            try? await session.analyzer.cancelAndFinishNow()
        }
        sessionBox = nil
        finalizedText.withLock { $0 = "" }
    }

    /// Move capture to the new device; the analyzer session carries on.
    func restartAudioCapture(inputDeviceID: AudioDeviceID?) async {
        guard isRecordingFlag else { return }
        capture?.switchDevice(to: inputDeviceID)
    }
}
