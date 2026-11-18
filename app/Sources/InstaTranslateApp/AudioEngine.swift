import AVFoundation
import Accelerate

/// Half-duplex audio for insta-translate.
///
/// Capture: built-in mic → 16 kHz mono PCM16, chunked into 32 ms (1024-byte)
/// frames aligned with the server (FRAME_BYTES).
///
/// Playback: server sends 200 ms chunks of int16 @48 kHz; we convert to
/// float32 and schedule on an AVAudioPlayerNode with a jitter buffer + pre-roll,
/// because the producer can run slightly slower than real time.
///
/// AEC: Phase 0 proved voice processing cannot start on this MacBook Pro's
/// built-in mic (-10875). We still try-with-fallback so headset mics get AEC,
/// and we expose `micMuted` so the app can duck the mic while playing back.
final class AudioEngine {
    static let micSampleRate: Double = 16000
    static let chunkSamples = 512              // 32 ms @16 kHz — matches server FRAME_BYTES

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?

    var onMicFrame: ((Data) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var onSpeakerLevel: ((Float) -> Void)?

    /// Ducking: when true, captured frames are not forwarded to the server.
    var micMuted = false { didSet { if micMuted { pendingMic.removeAll() } } }

    private(set) var isRunning = false
    private(set) var voiceProcessing = false

    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: AudioEngine.micSampleRate,
                                          channels: 1,
                                          interleaved: true)!
    private var playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 48000, channels: 1,
                                           interleaved: false)!

    private var pendingMic = Data()

    // Downstream jitter buffer.
    private var pendingPlay = Data()
    private let playChunkBytes = 9600 * 2      // 200 ms @48 kHz int16
    private var playFlushTimer: Timer?
    private let prerollBytes = 48000 * 2 * 6 / 10   // 0.6 s
    private var buffering = true
    private var queued = 0

    // MARK: - lifecycle

    func start() throws {
        guard !isRunning else { return }
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            NSLog("AudioEngine: voice processing unavailable (%@); retrying without", "\(error)")
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing vp: Bool) throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let input = engine.inputNode

        if vp { try input.setVoiceProcessingEnabled(true) }
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: micFormat) else {
            throw AudioError.converterUnavailable
        }
        converter = conv

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            self?.handleMic(buf)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
        voiceProcessing = vp
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        isRunning = false
        pendingMic.removeAll()
        pendingPlay.removeAll()
    }

    // MARK: - capture

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter else { return }

        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var consumed = false
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ptr = out.int16ChannelData?[0] else { return }

        let count = Int(out.frameLength)
        onMicLevel?(Self.rms(ptr, count))
        guard !micMuted else { return }

        pendingMic.append(Data(bytes: ptr, count: count * 2))
        let frameBytes = Self.chunkSamples * 2
        while pendingMic.count >= frameBytes {
            let frame = pendingMic.prefix(frameBytes)
            pendingMic.removeFirst(frameBytes)
            onMicFrame?(Data(frame))
        }
    }

    // MARK: - playback

    func play(_ data: Data, sampleRate: Double) {
        guard isRunning, !data.isEmpty else { return }
        if abs(playFormat.sampleRate - sampleRate) > 1 {
            rebuildPlayback(sampleRate: sampleRate)
        }
        pendingPlay.append(data)
        if buffering && pendingPlay.count < prerollBytes {
            scheduleFlushTimer()
            return
        }
        buffering = false
        drainPlaybackBuffer()
        if !pendingPlay.isEmpty { scheduleFlushTimer() }
    }

    func endOfUtterance() {
        playFlushTimer?.invalidate(); playFlushTimer = nil
        buffering = false
        drainPlaybackBuffer()
        if !pendingPlay.isEmpty {
            let rest = pendingPlay; pendingPlay.removeAll(); enqueue(rest)
        }
        buffering = true
    }

    private func drainPlaybackBuffer() {
        while pendingPlay.count >= playChunkBytes {
            let chunk = pendingPlay.prefix(playChunkBytes)
            pendingPlay.removeFirst(playChunkBytes)
            enqueue(Data(chunk))
        }
    }

    private func scheduleFlushTimer() {
        playFlushTimer?.invalidate()
        playFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, !self.pendingPlay.isEmpty else { return }
            self.buffering = false
            let rest = self.pendingPlay
            self.pendingPlay.removeAll()
            self.enqueue(rest)
            self.buffering = true
        }
    }

    private func enqueue(_ data: Data) {
        guard isRunning, data.count >= 2 else { return }
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                                frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        data.withUnsafeBytes { raw in
            guard let i16 = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            guard let out = buf.floatChannelData?[0] else { return }
            var scale: Float = 1.0 / 32768.0
            vDSP_vflt16(i16, 1, out, 1, vDSP_Length(n))
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(n))
        }
        if let ch = buf.floatChannelData?[0] { onSpeakerLevel?(Self.rms(ch, n)) }

        queued += 1
        player.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queued -= 1
                if self.queued == 0 && self.pendingPlay.count < self.prerollBytes {
                    self.buffering = true
                }
            }
        }
    }

    private func rebuildPlayback(sampleRate: Double) {
        playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1,
                                   interleaved: false)!
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        player.play()
    }

    func stopPlayback() {
        guard isRunning else { return }
        playFlushTimer?.invalidate(); playFlushTimer = nil
        pendingPlay.removeAll()
        buffering = true
        queued = 0
        player.stop()
        player.play()
    }

    // MARK: - helpers

    private static func rms(_ p: UnsafePointer<Int16>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += (Float(p[i]) / 32768.0) * (Float(p[i]) / 32768.0) }
        return sqrt(sum / Float(n))
    }

    private static func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return sqrt(sum / Float(n))
    }

    enum AudioError: LocalizedError {
        case noInputDevice
        case converterUnavailable
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone. Check System Settings › Sound › Input."
            case .converterUnavailable: return "Could not build the audio converter."
            }
        }
    }
}
