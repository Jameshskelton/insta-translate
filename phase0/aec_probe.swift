import Foundation
import AVFoundation

func ensureMicrophoneAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        var granted = false
        let semaphore = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        // Keep the run loop alive so TCC can deliver the callback.
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return granted
    default:
        return false
    }
}

func probe(voiceProcessing: Bool) {
    let engine = AVAudioEngine()
    let input = engine.inputNode

    if voiceProcessing {
        do {
            try input.setVoiceProcessingEnabled(true)
            print("  setVoiceProcessingEnabled(true): OK")
        } catch {
            print("  setVoiceProcessingEnabled(true) threw: \(error)")
        }
        print("  isVoiceProcessingEnabled: \(input.isVoiceProcessingEnabled)")
    }

    let format = input.inputFormat(forBus: 0)
    print("  input format: \(format.channelCount) ch @ \(Int(format.sampleRate)) Hz")

    engine.connect(input, to: engine.mainMixerNode, format: format)

    do {
        try engine.start()
        print("  engine.start(): OK")
        engine.stop()
    } catch let error as NSError {
        print("  engine.start(): FAILED domain=\(error.domain) code=\(error.code)")
        print("  description: \(error.localizedDescription)")
    }
}

guard ensureMicrophoneAccess() else {
    print("MIC ACCESS DENIED — grant access in System Settings > Privacy & Security > Microphone")
    exit(2)
}

print("=== AEC probe: voice processing OFF (control) ===")
probe(voiceProcessing: false)
print("=== AEC probe: voice processing ON ===")
probe(voiceProcessing: true)
