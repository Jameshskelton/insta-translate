import AVFoundation
import Foundation

// Headless mic→server relay. Compiles against the app's AudioEngine +
// WebSocketManager to reproduce/probe the "no speech detected" path without
// the UI. Usage:
//   swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
//     -framework AVFoundation -framework Accelerate mic_relay.swift \
//     ../app/Sources/InstaTranslateApp/AudioEngine.swift \
//     ../app/Sources/InstaTranslateApp/WebSocketManager.swift -o mic_relay
//   ./mic_relay
func requestMic() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        var granted = false
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return granted
    default: return false
    }
}

@main
struct MicRelay {
    static func main() {
        guard requestMic() else { print("MIC DENIED"); exit(2) }

        let audio = AudioEngine()
        let ws = WebSocketManager()
        var frames = 0
        var audioError: String?

        audio.onMicFrame = { data in
            frames += 1
            ws.sendAudio(data)
        }

        ws.onConnected = {
            print("CONNECTED; ptt_start + audio.start()")
            ws.sendJSON(["type": "session_config", "mode": "interpreter",
                         "src_lang": "en", "tgt_lang": "es"])
            ws.sendJSON(["type": "ptt_start"])
            do {
                try audio.start()
                print("AUDIO OK running=\(audio.isRunning) vp=\(audio.voiceProcessing)")
            } catch {
                audioError = "\(error)"
                print("AUDIO START ERROR: \(error)")
            }
        }
        ws.onJSON = { print("EV", $0) }
        ws.onDisconnected = { print("DISCONNECTED", $0) }
        ws.connect(to: "ws://127.0.0.1:3100/ws/voice/v2")

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            print("ptt_end after 6s; mic frames relayed = \(frames)")
            ws.sendJSON(["type": "ptt_end"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("done. audioError=\(audioError ?? "none")")
                exit(0)
            }
        }
        RunLoop.main.run()
    }
}
