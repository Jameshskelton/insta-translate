import Foundation
import Combine

/// One /ws/voice/v2 session. State the UI renders; audio plumbing lives on
/// AudioEngine; the WebSocket stays dumb. Latency is measured client-side.
/// Push-to-talk: press to listen, release to translate. The mic is only ever
/// fed to the server between press and release, so the app can never hear its
/// own playback and treat it as input (no AEC on the built-in mic).
@MainActor
final class Session: ObservableObject {
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL")
        ?? "ws://127.0.0.1:3100/ws/voice/v2"
    @Published var connected = false
    @Published var status = "idle"
    @Published var routes = ""

    @Published var srcLang = "en" { didSet { pushConfig() } }
    @Published var tgtLang = "es" { didSet { pushConfig() } }

    struct Turn: Identifiable {
        let id = UUID()
        var seq = 0
        var src = ""
        var out = ""
        var asrMs: Int?
        var mtMs: Int?
        var firstAudioMs: Int?
        var ttsAt: Date?
    }
    @Published var turns: [Turn] = []

    enum Stage: Int, Comparable {
        case idle, listening, asr, llm, tts
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }
    @Published var stage: Stage = .idle

    @Published var micLevel: Float = 0
    @Published var speakerLevel: Float = 0
    @Published var recording = false
    @Published var lastError = ""
    @Published var audioNote = ""

    /// CLI auto-test: `--text "sentence"` sends one text_input and logs events.
    private let autoText: String?
    private let ws = WebSocketManager()
    private let audio = AudioEngine()
    private var configDirty = false

    init(autoText: String? = nil) {
        self.autoText = autoText
        ws.onConnected = { [weak self] in
            Task { @MainActor in
                if self?.autoText != nil { self?.logLine("CONN connected") }
                self?.connected = true
                self?.status = "connected"
                self?.pushConfig()
                if let text = self?.autoText {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.sendDemo(text)
                    }
                }
            }
        }
        ws.onDisconnected = { [weak self] why in
            Task { @MainActor in
                if self?.autoText != nil { self?.logLine("CONN disconnected: \(why)") }
                self?.connected = false
                self?.status = "disconnected: \(why)"
                self?.stage = .idle
            }
        }
        ws.onJSON = { [weak self] obj in
            Task { @MainActor in self?.handle(obj) }
        }
        ws.onAudio = { [weak self] data in
            Task { @MainActor in self?.handleAudio(data) }
        }
        audio.onMicFrame = { [weak self] frame in
            Task { @MainActor in self?.sendMicFrame(frame) }
        }
        audio.onMicLevel = { [weak self] lvl in
            Task { @MainActor in self?.micLevel = lvl }
        }
        audio.onSpeakerLevel = { [weak self] lvl in
            Task { @MainActor in self?.speakerLevel = lvl }
        }

        // CLI auto-test cannot rely on the window scene ever mounting; drive
        // connection from here once the main run loop is up.
        if autoText != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.connect()
            }
        }
    }

    // MARK: - connection

    /// CLI-mode log line, force-flushed so headless runs can be observed live.
    private func logLine(_ s: String) {
        print(s)
        fflush(stdout)
    }

    func connect() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        status = "connecting…"
        if autoText != nil { logLine("CONN connecting…") }
        ws.connect(to: serverURL)
        // CLI auto-test does not touch the mic (no TCC prompt, no blocking).
        guard autoText == nil else { return }
        do {
            try audio.start()
            audioNote = audio.voiceProcessing
                ? ""
                : "echo cancellation unavailable on the built-in mic"
        } catch {
            lastError = "audio: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        ws.disconnect(); audio.stop()
        connected = false; status = "idle"; stage = .idle; recording = false
    }

    func onAppear() {
        // no-op; kept for future view-driven setup
    }

    private func pushConfig() {
        guard connected else { return }
        if recording { configDirty = true; return }   // no mid-press reconfig (DEVLOG §4.7)
        configDirty = false
        ws.sendJSON(["type": "session_config", "mode": "interpreter",
                     "src_lang": srcLang, "tgt_lang": tgtLang])
    }

    /// Only forward mic frames while the user is actually holding the button.
    private func sendMicFrame(_ frame: Data) {
        guard recording else { return }
        ws.sendAudio(frame)
    }

    // MARK: - push-to-talk

    func pttDown() {
        guard connected, !recording, autoText == nil else { return }
        audio.stopPlayback()
        audio.micMuted = false
        recording = true
        stage = .listening
        ws.sendJSON(["type": "ptt_start"])
    }

    func pttUp() {
        guard recording else { return }
        recording = false
        stage = .asr
        ws.sendJSON(["type": "ptt_end"])
        if configDirty { pushConfig() }
    }

    func interrupt() {
        audio.stopPlayback()
        stage = .idle
        ws.sendJSON(["type": "interrupt", "reason": "user"])
    }

    /// Start fresh: drop the transcript, stop any playback/in-flight work, and
    /// tell the server to clear its session state (segmenter, buffered frames).
    func clearConversation() {
        turns.removeAll()
        audio.stopPlayback()
        recording = false
        stage = .idle
        lastError = ""
        if connected {
            ws.sendJSON(["type": "reset"])
        }
        status = connected ? "connected — cleared" : "idle"
    }

    // MARK: - text input (demo / auto-test)

    func sendDemo(_ text: String) {
        guard connected else { lastError = "not connected"; return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        stage = .llm
        turns.append(Turn(src: line))
        ws.sendJSON(["type": "text_input", "text": line])
    }

    // MARK: - server events

    private func handle(_ obj: [String: Any]) {
        if autoText != nil { logLine("EVENT \(obj)") }   // headless validation log

        guard let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            pushConfig()
        case "session_config_ack":
            routes = obj["routes"] as? String ?? ""
        case "segment_committed":
            stage = .asr
            turns.append(Turn(seq: (obj["seq"] as? NSNumber)?.intValue ?? 0))
        case "asr":
            let i = turnIndex(for: obj)
            turns[i].src = obj["text"] as? String ?? ""
            turns[i].asrMs = (obj["latency_ms"] as? NSNumber)?.intValue
            stage = .llm
        case "translation", "llm":
            let i = turnIndex(for: obj)
            turns[i].out = obj["text"] as? String ?? ""
            turns[i].mtMs = (obj["latency_ms"] as? NSNumber)?.intValue
            if turns[i].ttsAt == nil { turns[i].ttsAt = Date() }
            stage = .tts
        case "audio_start":
            stage = .tts
            audio.micMuted = true
            let i = turnIndex(for: obj)
            guard turns[i].firstAudioMs == nil else { break }
            if let t = turns[i].ttsAt {
                turns[i].firstAudioMs = Int(Date().timeIntervalSince(t) * 1000)
            } else if let ms = (obj["tts_latency_ms"] as? NSNumber)?.intValue {
                turns[i].firstAudioMs = ms
            }
        case "audio_end":
            audio.endOfUtterance()
            audio.micMuted = false
        case "turn_end":
            stage = .idle
            if autoText != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.disconnect()
                    exit(0)
                }
            }
        case "interrupted":
            audio.stopPlayback(); audio.micMuted = false
            stage = .idle
        case "no_speech":
            lastError = "no speech detected"
            stage = .idle
        case "error":
            lastError = "\(obj["stage"] ?? ""): \(obj["message"] ?? "")"
            stage = .idle
        default:
            break
        }
    }

    private func turnIndex(for obj: [String: Any]) -> Int {
        let seq = (obj["seq"] as? NSNumber)?.intValue ?? 0
        if seq > 0, let i = turns.lastIndex(where: { $0.seq == seq }) { return i }
        if turns.isEmpty { turns.append(Turn(seq: seq)) }
        return turns.count - 1
    }

    private func handleAudio(_ data: Data) {
        if !turns.isEmpty, turns[turns.count - 1].firstAudioMs == nil,
           let t = turns[turns.count - 1].ttsAt {
            turns[turns.count - 1].firstAudioMs = Int(Date().timeIntervalSince(t) * 1000)
        }
        audio.play(data, sampleRate: 48000)
    }
}
