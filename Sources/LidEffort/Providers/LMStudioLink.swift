import Foundation

/// The wire LM Studio's SDK speaks over a WebSocket on the server's own port —
/// the channel `lms ps` uses, and the only place the runtime says what a model
/// is *doing* rather than what is loaded. Kept apart from the socket so the
/// framing can be tested without one. Verified against 0.4.24 on 2026-09-10.
///
/// Every connection opens with one auth frame and is answered
/// `{"success":true}`. Calls are `{"type":"rpcCall","endpoint":…,"callId":n}`
/// with a `parameter` only when the endpoint takes one — sending `{}` to one
/// that does not is refused as a type error — and come back as `rpcResult`,
/// `rpcError`, or a `communicationWarning` when the frame itself was wrong.
enum LMStudioWire {
    static let authVersion = 1

    /// The first frame on every connection.
    ///
    /// An API token is `sk-lm-<id>:<passkey>` and is sent as the two halves
    /// LM Studio reads it as. With no token — the shipping default, where
    /// authentication is off — any identifier and passkey are accepted, so a
    /// fresh random pair names this connection without pretending to be a
    /// token. A token in the wrong shape is still sent as-is, so the server
    /// refuses it and Settings can say so, rather than this code guessing.
    static func authFrame(token: String?, random: () -> String = { randomKey(20) }) -> [String: Any] {
        let identifier: String
        let passkey: String
        if let token, let parts = LMStudioCredentials.parts(of: token) {
            identifier = parts.clientIdentifier
            passkey = parts.clientPasskey
        } else if let token {
            identifier = "spyx"
            passkey = token
        } else {
            identifier = "spyx-" + random().prefix(8)
            passkey = random()
        }
        return ["authVersion": authVersion, "clientIdentifier": identifier, "clientPasskey": passkey]
    }

    static func rpcCall(endpoint: String, callId: Int, parameter: Any? = nil) -> [String: Any] {
        var frame: [String: Any] = ["type": "rpcCall", "endpoint": endpoint, "callId": callId]
        if let parameter { frame["parameter"] = parameter }
        return frame
    }

    /// The one call that says whether an instance is idle, reading a prompt or
    /// generating, and how many requests are queued behind it.
    static func processingStateParameter(instanceReference: String) -> [String: Any] {
        ["specifier": ["type": "instanceReference", "instanceReference": instanceReference],
         "throwIfNotFound": true]
    }

    enum Inbound {
        case authReply(success: Bool, error: String?)
        case rpcResult(callId: Int, result: Any)
        case rpcError(callId: Int, message: String)
        /// The server objecting to a frame: an unknown endpoint, a parameter
        /// of the wrong shape. Carries no callId, so it fails whatever was asked.
        case warning(String)
        case other
    }

    static func decode(_ text: String) -> Inbound? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { return nil }
        if let success = object["success"] as? Bool {
            let error = (object["error"] as? [String: Any])?["title"] as? String ?? object["error"] as? String
            return .authReply(success: success, error: error)
        }
        switch object["type"] as? String {
        case "rpcResult":
            guard let callId = object["callId"] as? Int else { return .other }
            return .rpcResult(callId: callId, result: object["result"] ?? NSNull())
        case "rpcError":
            guard let callId = object["callId"] as? Int else { return .other }
            let error = object["error"] as? [String: Any]
            return .rpcError(callId: callId,
                             message: error?["title"] as? String ?? error?["message"] as? String ?? "error")
        case "communicationWarning":
            return .warning(object["warning"] as? String ?? "communication warning")
        default:
            return .other
        }
    }

    static func encode(_ frame: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    static func randomKey(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

/// `llm.getInstanceProcessingState`: `{"status":"generating","queued":1}`.
struct LMStudioProcessingState: Equatable {
    enum Status: Equatable {
        case idle
        case processingPrompt
        case generating
        case computingEmbedding
        /// A status this version does not know. Shown as nothing rather than
        /// guessed at.
        case other(String)
    }

    let status: Status
    let queued: Int

    init(status: Status, queued: Int) {
        self.status = status
        self.queued = queued
    }

    init?(_ result: Any) {
        guard let object = result as? [String: Any], let status = object["status"] as? String else { return nil }
        switch status {
        case "idle":               self.status = .idle
        case "processingPrompt":   self.status = .processingPrompt
        case "generating":         self.status = .generating
        case "computingEmbedding": self.status = .computingEmbedding
        default:                   self.status = .other(status)
        }
        queued = max(0, (object["queued"] as? NSNumber).map { Int(truncating: $0) } ?? 0)
    }

    /// The two phases a language model spends on a request.
    var phase: LocalModelActivity.Phase? {
        switch status {
        case .processingPrompt: return .processingPrompt
        case .generating:       return .generating
        case .idle, .computingEmbedding, .other: return nil
        }
    }
}

/// One entry of `llm.listLoaded`, the handle the state call wants.
struct LMStudioLoadedInstance: Equatable {
    let identifier: String
    let instanceReference: String
    let type: String?
    let modelKey: String?

    var isLanguageModel: Bool { type == "llm" }

    static func parse(_ result: Any) -> [LMStudioLoadedInstance] {
        guard let list = result as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let identifier = item["identifier"] as? String, !identifier.isEmpty,
                  let reference = item["instanceReference"] as? String, !reference.isEmpty
            else { return nil }
            return LMStudioLoadedInstance(identifier: identifier, instanceReference: reference,
                                          type: item["type"] as? String, modelKey: item["modelKey"] as? String)
        }
    }
}

enum LMStudioLinkError: LocalizedError, Equatable {
    case unauthorized(String?)
    case remote(String)
    case badFrame
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unauthorized(let why): return why ?? LMStudioError.needsToken.errorDescription
        case .remote(let why):       return why
        case .badFrame:              return "LM Studio sent a frame this version does not understand."
        case .timedOut:              return "LM Studio did not answer in time."
        }
    }
}

/// What the monitor needs of a connection, so a test can stand one in.
protocol LMStudioCalling: AnyObject {
    func call(_ endpoint: String, parameter: Any?) async throws -> Any
    func close() async
}

/// One WebSocket to one namespace, opened on first use and reopened after any
/// failure. Calls are made one at a time — the monitor is the only caller and
/// it asks sequentially — so a reply is matched to the call still waiting.
actor LMStudioLink: LMStudioCalling {
    private let endpoint: URL
    private let namespace: String
    private let token: @Sendable () -> String?
    private let session: URLSession
    private let timeout: TimeInterval
    private var socket: URLSessionWebSocketTask?
    private var nextCallId = 0

    init(endpoint: URL, namespace: String = "llm", timeout: TimeInterval = 3,
         token: @escaping @Sendable () -> String?, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.namespace = namespace
        self.timeout = timeout
        self.token = token
        self.session = session ?? OllamaLocalProvider.makeSession()
    }

    func call(_ endpoint: String, parameter: Any? = nil) async throws -> Any {
        let socket = try await connected()
        nextCallId += 1
        let callId = nextCallId
        do {
            try await socket.send(.string(LMStudioWire.encode(
                LMStudioWire.rpcCall(endpoint: endpoint, callId: callId, parameter: parameter))))
            while true {
                switch LMStudioWire.decode(try await receive(socket)) {
                case .rpcResult(let id, let result) where id == callId:
                    return result
                case .rpcError(let id, let message) where id == callId:
                    throw LMStudioLinkError.remote(message)
                case .warning(let message):
                    throw LMStudioLinkError.remote(message)
                default:
                    // A late answer to a call that timed out, or a frame this
                    // version does not read; the one asked for is still coming.
                    continue
                }
            }
        } catch {
            drop()
            throw error
        }
    }

    func close() {
        drop()
    }

    private func drop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connected() async throws -> URLSessionWebSocketTask {
        if let socket { return socket }
        let socket = session.webSocketTask(with: LMStudioEndpoint.websocketURL(endpoint, namespace: namespace))
        socket.resume()
        do {
            try await socket.send(.string(LMStudioWire.encode(LMStudioWire.authFrame(token: token()))))
            guard case .authReply(let success, let error) = LMStudioWire.decode(try await receive(socket))
            else { throw LMStudioLinkError.badFrame }
            guard success else { throw LMStudioLinkError.unauthorized(error) }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
        self.socket = socket
        return socket
    }

    /// One text frame, or a timeout. The socket is cancelled on timeout so the
    /// orphaned receive fails instead of outliving the call.
    private func receive(_ socket: URLSessionWebSocketTask) async throws -> String {
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                guard case .string(let text) = try await socket.receive() else { throw LMStudioLinkError.badFrame }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                socket.cancel(with: .goingAway, reason: nil)
                throw LMStudioLinkError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
