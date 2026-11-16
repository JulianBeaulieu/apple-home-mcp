import Foundation
import Network
import os

/// Minimal HTTP/1.1 server on Network.framework. One request at a time per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public enum Bind: Sendable, Equatable {
        case loopback
        case allInterfaces
    }

    public let port: UInt16
    public let bind: Bind
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "apple-home-mcp.http")
    private let log = Logger(subsystem: "apple-home-mcp", category: "http")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var lastError: String?
    public var onStateChange: (@Sendable (String) -> Void)?

    public init(port: UInt16, bind: Bind, handler: @escaping Handler) {
        self.port = port
        self.bind = bind
        self.handler = handler
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        switch bind {
        case .loopback:
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        case .allInterfaces:
            break
        }
        let listener = try bind == .loopback ? NWListener(using: params) : NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastError = nil
                self.onStateChange?("listening")
            case .failed(let error):
                self.lastError = "\(error)"
                self.log.error("listener failed: \(String(describing: error), privacy: .public)")
                self.onStateChange?("failed: \(error)")
            case .cancelled:
                self.onStateChange?("stopped")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            for c in self.connections.values { c.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        var remote: String?
        if case .hostPort(let host, _) = conn.endpoint { remote = "\(host)" }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(conn, parser: HTTPRequestParser(), remote: remote)
    }

    private func receive(_ conn: NWConnection, parser: HTTPRequestParser, remote: String?) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var parser = parser
            if let data, !data.isEmpty { parser.append(data) }
            do {
                if let request = try parser.next(remoteAddress: remote) {
                    let keepAlive = request.header("connection")?.lowercased() != "close"
                    let handler = self.handler
                    Task {
                        let response = await handler(request)
                        conn.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { _ in
                            if keepAlive {
                                self.receive(conn, parser: parser, remote: remote)
                            } else {
                                conn.cancel()
                            }
                        })
                    }
                    return
                }
            } catch {
                let status: Int
                switch error as? HTTPRequestParser.ParseError {
                case .bodyTooLarge: status = 413
                case .headersTooLarge: status = 431
                default: status = 400
                }
                conn.send(content: HTTPResponse.text("bad request\n", status: status).serialized(keepAlive: false),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, parser: parser, remote: remote)
        }
    }
}
