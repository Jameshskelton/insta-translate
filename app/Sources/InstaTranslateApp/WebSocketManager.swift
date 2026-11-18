import Foundation

/// Minimal WebSocket client for /ws/voice/v2.
/// Binary messages = 48 kHz PCM16 audio; text messages = JSON control.
final class WebSocketManager: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?

    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onJSON: (([String: Any]) -> Void)?

    var isConnected: Bool { task?.state == .running }

    func connect(to urlString: String) {
        disconnect()
        guard let url = URL(string: urlString) else {
            onDisconnected?("Invalid URL")
            return
        }
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: url)
        task?.resume()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private(set) var audioFramesSent = 0
    private(set) var audioSendErrors = 0

    func sendAudio(_ data: Data) {
        guard let task, task.state == .running else {
            audioSendErrors += 1
            return
        }
        audioFramesSent += 1
        task.send(.data(data)) { [weak self] err in
            if err != nil { self?.audioSendErrors += 1 }
        }
    }

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        onConnected?()
        startReceiving()
        startPing()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let msg = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed"
        onDisconnected?(msg)
    }

    /// One-shot, non-retrying receive loop. Capture the task captured at call
    /// time so a reconnected socket never silently kills it.
    private func startReceiving() {
        let t = task
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data): self.onAudio?(data)
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onJSON?(json)
                    }
                @unknown default: break
                }
                if let t, t === self.task { self.startReceiving() }
            case .failure:
                self.onDisconnected?("Connection lost")
            }
        }
    }

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in
                    if error != nil { self?.onDisconnected?("Ping failed") }
                }
            }
        }
    }
}
