import Foundation

/// Keeps a WebSocket open to the relay's `/live` endpoint and calls `onEvent` when another device
/// uploads something. Reconnects with backoff; "ping" is answered by the relay without waking it.
final class LiveConnection: @unchecked Sendable {
    private let url: URL
    private let onStatus: @Sendable (Bool) -> Void
    private let onEvent: @Sendable () -> Void
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var backoff: TimeInterval = 2
    private var pingTimer: Timer?

    init(url: URL, onStatus: @escaping @Sendable (Bool) -> Void, onEvent: @escaping @Sendable () -> Void) {
        self.url = url
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        onStatus(false)
    }

    private func connect() {
        guard !stopped else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                self?.task?.send(.string("ping")) { _ in }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(let message):
                self.backoff = 2
                self.onStatus(true)
                if case .string(let text) = message, text != "pong" { self.onEvent() }
                self.receive(on: task)
            case .failure:
                self.onStatus(false)
                guard !self.stopped else { return }
                let delay = self.backoff
                self.backoff = min(self.backoff * 2, 60)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
            }
        }
    }
}
