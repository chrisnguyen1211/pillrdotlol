import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Loopback HTTP transport. Bodies exist only while forwarding a request; no
/// request logging, URL cache, cookies, redirects, or external proxy is used.
// Lifecycle calls are serialized by OllamaActivityRelay; channel state and
// callbacks are confined to the single NIO event loop.
final class OllamaRelayServer: @unchecked Sendable {
    typealias Observer = (UUID, String, Bool) -> Void
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var listener: Channel?
    // Accessed only on the group's single event loop.
    private var clients: [ObjectIdentifier: Channel] = [:]
    private let upstream: URL
    private let observe: Observer
    private let onPerformance: (String, LocalModelPerformance) -> Void
    private var stopped = false

    init(upstream: URL,
         onPerformance: @escaping (String, LocalModelPerformance) -> Void = { _, _ in },
         observe: @escaping Observer) {
        self.upstream = upstream
        self.onPerformance = onPerformance
        self.observe = observe
    }

    func start(port: Int = 11435) async throws -> Int {
        let endpoint = try OllamaEndpoint.parse(upstream.absoluteString)
        guard port == 0 || (endpoint.port ?? 80) != port else { throw OllamaError.invalidEndpoint }
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                clients[ObjectIdentifier(channel)] = channel
                channel.closeFuture.whenComplete { [weak self, weak channel] _ in
                    if let channel { self?.clients.removeValue(forKey: ObjectIdentifier(channel)) }
                }
                return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                                     withErrorHandling: true)
                    .flatMap {
                        channel.pipeline.addHandler(RelayRequestHandler(upstream: endpoint,
                            observe: self.observe, onPerformance: self.onPerformance))
                    }
            }
            .bind(host: "127.0.0.1", port: port).get()
        listener = channel
        return channel.localAddress!.port!
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if let listener { try? await listener.close().get() }
        let channels = try? await group.next().submit { Array(self.clients.values) }.get()
        for channel in channels ?? [] { try? await channel.close().get() }
        try? await group.shutdownGracefully()
    }
}

private func relayHeaders(_ original: HTTPHeaders) -> HTTPHeaders {
    let nominated = original["connection"].flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    let hop = Set(nominated + ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                               "te", "trailer", "transfer-encoding", "upgrade"])
    return HTTPHeaders(original.filter { !hop.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
}

// Browser requests from third-party websites must not reach the loopback relay (CSRF / drive-by attacks).
// Sandboxed iframes (`<iframe sandbox="allow-scripts">`) and data: URLs serialize origin as "null".
// Rejecting "null" prevents drive-by CSRF attacks from untrusted web pages; native CLI callers do not send Origin at all.
func isLoopbackOrigin(_ origin: String) -> Bool {
    let trimmed = origin.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.caseInsensitiveCompare("null") == .orderedSame { return false }
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.user == nil, url.password == nil,
          url.path.isEmpty || url.path == "/",
          url.query == nil,
          url.fragment == nil,
          let host = url.host?.lowercased(),
          ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
        return false
    }
    if let port = url.port { return (1...65535).contains(port) }
    if trimmed.hasSuffix(":") || trimmed.hasSuffix(":/") { return false }
    return true
}

private final class RelayRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private let upstream: URL
    private let observe: OllamaRelayServer.Observer
    private let onPerformance: (String, LocalModelPerformance) -> Void
    private let id = UUID()
    private var head: HTTPRequestHead?
    private var body = Data()
    private var forwarding = false
    private var upstreamChannel: Channel?
    private var downstream: Channel?
    private var responded = false
    private var parser: OllamaThinkingStream?

    init(upstream: URL, observe: @escaping OllamaRelayServer.Observer,
         onPerformance: @escaping (String, LocalModelPerformance) -> Void) {
        self.upstream = upstream
        self.observe = observe
        self.onPerformance = onPerformance
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !forwarding else { return }
        switch unwrapInboundIn(data) {
        case .head(let request):
            let port = context.channel.localAddress!.port!
            let hosts = request.headers["host"]
            guard hosts.count == 1,
                  ["127.0.0.1:\(port)", "localhost:\(port)"].contains(hosts[0].lowercased()),
                  request.uri.hasPrefix("/"), !request.uri.hasPrefix("//"),
                  !request.uri.contains("\\"), request.method != .CONNECT,
                  request.headers["upgrade"].isEmpty else {
                fail(context.channel, status: .badRequest); return
            }
            let origins = request.headers["origin"]
            let crossSite = request.headers["sec-fetch-site"].contains { $0.caseInsensitiveCompare("cross-site") == .orderedSame }
            guard !crossSite, origins.count <= 1, origins.allSatisfy(isLoopbackOrigin) else {
                fail(context.channel, status: .forbidden); return
            }
            head = request
            if request.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(
                    HTTPResponseHead(version: .http1_1, status: .continue))), promise: nil)
            }
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= 32 * 1024 * 1024 else {
                fail(context.channel, status: .payloadTooLarge); return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { fail(context.channel, status: .badRequest); return }
            forwarding = true
            downstream = context.channel
            let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "")
            parser = OllamaThinkingStream(path: path, body: body)
            connect(head: head, channel: context.channel)
        }
    }

    private func connect(head: HTTPRequestHead, channel: Channel) {
        let host = (upstream.host ?? "127.0.0.1").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        ClientBootstrap(group: channel.eventLoop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { upstream in
                upstream.pipeline.addHTTPClientHandlers().flatMap {
                    upstream.pipeline.addHandler(RelayResponseHandler(owner: self))
                }
            }
            .connect(host: host, port: upstream.port ?? 80).whenComplete { [self] result in
                switch result {
                case .failure:
                    body.removeAll(); fail(channel, status: .badGateway)
                case .success(let connection):
                    guard channel.isActive else { connection.close(promise: nil); return }
                    upstreamChannel = connection
                    var headers = relayHeaders(head.headers)
                    headers.remove(name: "host")
                    headers.remove(name: "expect")
                    headers.replaceOrAdd(name: "host", value: "\(upstream.host ?? "127.0.0.1"):\(upstream.port ?? 80)")
                    headers.replaceOrAdd(name: "content-length", value: String(body.count))
                    headers.replaceOrAdd(name: "accept-encoding", value: "identity")
                    headers.replaceOrAdd(name: "connection", value: "close")
                    connection.write(HTTPClientRequestPart.head(HTTPRequestHead(
                        version: .http1_1, method: head.method, uri: head.uri, headers: headers)), promise: nil)
                    var buffer = connection.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    body.removeAll()
                    connection.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                    connection.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    connection.read()
                }
            }
    }

    fileprivate func receive(_ part: HTTPClientResponsePart) {
        guard let channel = downstream, channel.isActive else { return }
        switch part {
        case .head(var response):
            if response.status.code < 200 { return }
            responded = true
            if !(200..<300).contains(response.status.code) || !response.headers["content-encoding"].isEmpty {
                parser = nil
            }
            response.headers = relayHeaders(response.headers)
            response.headers.replaceOrAdd(name: "connection", value: "close")
            channel.writeAndFlush(HTTPServerResponsePart.head(response), promise: nil)
        case .body(let buffer):
            for (model, active) in parser?.append(Data(buffer.readableBytesView)) ?? [] { observe(id, model, active) }
            publishPerformance()
            // One socket read at a time; a slow client cannot accumulate the
            // model's entire output in the relay's outbound buffer.
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
                .whenFailure { _ in channel.close(promise: nil) }
        case .end:
            parser?.finish()
            publishPerformance()
            observe(id, "", false)
            parser = nil
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    private func publishPerformance() {
        if let measurement = parser?.takePerformance(), let model = parser?.model {
            onPerformance(model, measurement)
        }
    }

    fileprivate func readMore() {
        guard let channel = downstream, channel.isActive else { return }
        if channel.isWritable { upstreamChannel?.read() }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) { readMore() }

    fileprivate func upstreamFailed() {
        observe(id, "", false)
        if let channel = downstream {
            if responded { channel.close(promise: nil) }
            else { fail(channel, status: .badGateway) }
        }
    }

    private func fail(_ channel: Channel, status: HTTPResponseStatus) {
        forwarding = true
        body.removeAll()
        observe(id, "", false)
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
            version: .http1_1, status: status,
            headers: ["content-length": "0", "connection": "close"])), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        observe(id, "", false)
        upstreamChannel?.close(promise: nil)
        upstreamChannel = nil
        downstream = nil
        body.removeAll()
        parser = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class RelayResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private weak var owner: RelayRequestHandler?
    private var completed = false
    init(owner: RelayRequestHandler) { self.owner = owner }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .end = part { completed = true }
        owner?.receive(part)
    }
    func channelReadComplete(context: ChannelHandlerContext) { if !completed { owner?.readMore() } }
    func channelInactive(context: ChannelHandlerContext) { if !completed { owner?.upstreamFailed() } }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.upstreamFailed()
        context.close(promise: nil)
    }
}
