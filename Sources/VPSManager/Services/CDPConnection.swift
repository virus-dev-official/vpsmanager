import Foundation

/// A JSON object as decoded by JSONSerialization. Wrapped so it can cross
/// concurrency boundaries (continuations, main-actor hops) without the compiler
/// treating every `[String: Any]` as a data race — the dictionaries are created
/// once from a decoded message and never mutated afterwards.
struct CDPPayload: @unchecked Sendable {
    let json: [String: Any]
    subscript(key: String) -> Any? { json[key] }
}

enum CDPError: LocalizedError {
    case closed
    case timeout(String)
    case protocolError(method: String, message: String)
    case badMessage

    var errorDescription: String? {
        switch self {
        case .closed: return "The connection to the browser was closed."
        case .timeout(let what): return "The browser didn't answer in time (\(what))."
        case .protocolError(let method, let message): return "\(method) failed: \(message)"
        case .badMessage: return "Received a malformed message from the browser."
        }
    }
}

/// Minimal Chrome DevTools Protocol client over a single WebSocket.
///
/// Talks to the *browser-level* endpoint and uses flattened target sessions
/// (`Target.attachToTarget` with `flatten: true`), so every tab is driven over this
/// one socket by tagging messages with a `sessionId`.
///
/// Ordering matters for input (a mouse press must reach the page before its
/// release), so every outgoing message — awaited or fire-and-forget — goes through
/// the same synchronous `enqueue`, and URLSessionWebSocketTask preserves send order.
///
/// Callbacks (`onEvent`, `onClose`) fire on the connection's private serial queue;
/// consumers hop to the main actor themselves. That keeps heavy work (decoding
/// screencast JPEGs) off the main thread.
final class CDPConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<CDPPayload, Error>) -> Void] = [:]
    private var pendingMethods: [Int: String] = [:]
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isClosed = false

    var onEvent: (@Sendable (_ method: String, _ params: CDPPayload, _ sessionID: String?) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "vpsmanager.cdp"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60 * 60 * 24
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: Lifecycle

    func connect(timeout: TimeInterval = 10) async throws {
        let task = urlSession.webSocketTask(with: url)
        // Screencast frames are base64 JPEGs; a sharp 2x frame of a big window can
        // exceed the 1 MB default comfortably.
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            openContinuation = continuation
            lock.unlock()
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveOpen(.failure(CDPError.timeout("opening the DevTools socket")))
            }
        }
        receiveNext()
    }

    func close() {
        shutdown(error: nil, notify: false)
    }

    private func resolveOpen(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func shutdown(error: Error?, notify: Bool) {
        lock.lock()
        if isClosed { lock.unlock(); return }
        isClosed = true
        let waiting = pending
        pending.removeAll()
        pendingMethods.removeAll()
        lock.unlock()

        resolveOpen(.failure(error ?? CDPError.closed))
        for callback in waiting.values { callback(.failure(CDPError.closed)) }
        task?.cancel(with: .goingAway, reason: nil)
        // URLSession retains its delegate until invalidated — without this the
        // connection object (and its session) would leak.
        urlSession.invalidateAndCancel()
        if notify { onClose?(error) }
        onEvent = nil
        onClose = nil
    }

    // MARK: Sending

    /// Sends a command and waits for its result.
    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:], sessionID: String? = nil, timeout: TimeInterval = 30) async throws -> CDPPayload {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CDPPayload, Error>) in
            let id = enqueue(method, params, sessionID: sessionID) { result in
                continuation.resume(with: result)
            }
            guard let id else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(id, .failure(CDPError.timeout(method)))
            }
        }
    }

    /// Sends a command without waiting for (or caring about) its result. Used for
    /// input events and frame acks, where latency matters more than confirmation.
    func fire(_ method: String, _ params: [String: Any] = [:], sessionID: String? = nil) {
        enqueue(method, params, sessionID: sessionID, callback: nil)
    }

    @discardableResult
    private func enqueue(_ method: String, _ params: [String: Any], sessionID: String?, callback: ((Result<CDPPayload, Error>) -> Void)?) -> Int? {
        lock.lock()
        if isClosed || task == nil {
            lock.unlock()
            callback?(.failure(CDPError.closed))
            return nil
        }
        let id = nextID
        nextID += 1
        if let callback {
            pending[id] = callback
            pendingMethods[id] = method
        }
        let task = self.task
        lock.unlock()

        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { message["sessionId"] = sessionID }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            complete(id, .failure(CDPError.badMessage))
            return nil
        }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.complete(id, .failure(error)) }
        }
        return id
    }

    private func complete(_ id: Int, _ result: Result<CDPPayload, Error>) {
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        pendingMethods.removeValue(forKey: id)
        lock.unlock()
        callback?(result)
    }

    // MARK: Receiving

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handle(Data(text.utf8))
                case .data(let data): self.handle(data)
                @unknown default: break
                }
                self.receiveNext()
            case .failure(let error):
                self.shutdown(error: error, notify: true)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                lock.lock()
                let method = pendingMethods[id] ?? "Command"
                lock.unlock()
                complete(id, .failure(CDPError.protocolError(method: method, message: message)))
            } else {
                complete(id, .success(CDPPayload(json: object["result"] as? [String: Any] ?? [:])))
            }
        } else if let method = object["method"] as? String {
            let params = CDPPayload(json: object["params"] as? [String: Any] ?? [:])
            onEvent?(method, params, object["sessionId"] as? String)
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resolveOpen(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        shutdown(error: CDPError.closed, notify: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        shutdown(error: error ?? CDPError.closed, notify: true)
    }
}
