import SwiftUI

// No SwiftUI `Button` anywhere: on macOS 26 + Swift 6.3, a plain Button click
// aborts inside `_ButtonGesture` (VoxWeft DEVLOG §7.2). Taps/holds go through
// gestures only.

private struct Tappable: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onTapGesture(perform: action)
    }
}
private extension View {
    func tappable(_ action: @escaping () -> Void) -> some View { modifier(Tappable(action: action)) }
}

private let languages = ["en", "es", "zh", "ja", "ko", "fr", "de", "it",
                         "pt", "ru", "ar", "hi", "vi", "id", "ms", "th"]

@main
struct InstaTranslateApp: App {
    @StateObject private var session: Session

    init() {
        let args = CommandLine.arguments
        var autoText: String?
        if let i = args.firstIndex(of: "--text"), i + 1 < args.count {
            autoText = args[i + 1]
        }
        if autoText != nil { print("APP init (CLI)"); fflush(stdout) }
        _session = StateObject(wrappedValue: Session(autoText: autoText))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onAppear { session.onAppear() }
                .frame(minWidth: 640, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct ContentView: View {
    @EnvironmentObject private var s: Session

    var body: some View {
        VStack(spacing: 12) {
            connectionBar
            configBar
            transcript
            statusBar
            controls
        }
        .padding(16)
    }

    // MARK: connection

    private var connectionBar: some View {
        HStack(spacing: 8) {
            TextField("ws://127.0.0.1:3100/ws/voice/v2", text: $s.serverURL)
                .textFieldStyle(.roundedBorder)
            Text(s.connected ? "● connected" : "○ offline").font(.caption.monospaced())
            Pill(text: s.connected ? "Disconnect" : "Connect", tint: s.connected ? .red : .blue)
                .tappable { s.connected ? s.disconnect() : s.connect() }
        }
    }

    private var configBar: some View {
        HStack(spacing: 8) {
            Picker("Source", selection: $s.srcLang) {
                ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
            }.fixedSize()
            Image(systemName: "arrow.right").font(.caption)
            Picker("Target", selection: $s.tgtLang) {
                ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
            }.fixedSize()
            Text(s.routes).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Pill(text: "Test", tint: .purple).tappable { s.sendDemo("The weather is lovely today, let us go for a walk.") }
            Pill(text: "■ Stop", tint: .orange).tappable { s.interrupt() }
        }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { _ in
            ScrollView {
                if s.turns.isEmpty {
                    Text("Press and hold the microphone to speak.\nRelease to translate.\nNothing leaves this machine.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(s.turns) { t in
                            TurnCard(turn: t)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            StageBox("ASR", on: s.stage >= .asr)
            StageBox("MT", on: s.stage >= .llm)
            StageBox("TTS", on: s.stage >= .tts)
            LevelMeter(name: "mic", value: s.micLevel)
            LevelMeter(name: "spk", value: s.speakerLevel)
            Spacer()
            if !s.lastError.isEmpty {
                Text(s.lastError).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Text(s.audioNote).font(.caption2).foregroundStyle(.orange).lineLimit(1)
        }
    }

    // MARK: controls

    private var controls: some View {
        let enabled = s.connected
        return HStack {
            Spacer()
            ZStack {
                Circle().fill(s.recording ? Color.red : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 76, height: 76)
                Image(systemName: s.recording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !s.recording && enabled { s.pttDown() } }
                    .onEnded { _ in s.pttUp() }
            )
            .help("Press and hold to listen — release to translate")
            Spacer()
        }
    }
}

private struct TurnCard: View {
    let turn: Session.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !turn.src.isEmpty {
                Text(turn.src).font(.body)
            }
            if !turn.out.isEmpty {
                Text(turn.out).font(.body.weight(.medium))
            }
            HStack(spacing: 8) {
                if let a = turn.asrMs { Chip("asr \(a)ms") }
                if let m = turn.mtMs { Chip("mt \(m)ms") }
                if let f = turn.firstAudioMs { Chip("first audio \(f)ms") }
            }
            Divider()
        }
        .padding(.vertical, 2)
    }
}

private struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(nsColor: .quaternarySystemFill)).clipShape(Capsule())
    }
}

private struct Pill: View {
    let text: String
    let tint: Color
    init(text: String, tint: Color) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 5)
            .background(tint.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

private struct StageBox: View {
    let name: String
    let on: Bool
    init(_ name: String, on: Bool) { self.name = name; self.on = on }
    var body: some View {
        Text(name).font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? Color.green.opacity(0.8) : Color(nsColor: .quaternarySystemFill))
            .foregroundStyle(on ? .white : .secondary)
            .clipShape(Capsule())
    }
}

private struct LevelMeter: View {
    let name: String
    let value: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 9))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .quaternarySystemFill))
                    Capsule().fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(width: 56, height: 5)
        }
    }
}
