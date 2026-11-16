import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var headers: [String: String]  // lower-cased names
    public var body: Data
    public var remoteAddress: String?

    public init(method: String, path: String, query: String? = nil, headers: [String: String] = [:], body: Data = Data(), remoteAddress: String? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + extraHeaders, body: value.serialized())
    }

    public static func text(_ text: String, status: Int, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + extraHeaders, body: Data(text.utf8))
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var names = Set<String>()
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
            names.insert(k.lowercased())
        }
        if !names.contains("content-length") { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// Incremental HTTP/1.1 request parser (Content-Length bodies only; chunked uploads are rejected).
public struct HTTPRequestParser {
    public enum ParseError: Error, Equatable {
        case malformed
        case headersTooLarge
        case bodyTooLarge
        case unsupportedTransferEncoding
    }

    public static let maxHeaderBytes = 32 * 1024
    public var maxBodyBytes: Int
    private var buffer = Data()

    public init(maxBodyBytes: Int = 1 * 1024 * 1024) {
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete request if one is buffered, nil if more data is needed.
    public mutating func next(remoteAddress: String? = nil) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > HTTPRequestParser.maxHeaderBytes { throw ParseError.headersTooLarge }
            return nil
        }
        if headerEnd.lowerBound - buffer.startIndex > HTTPRequestParser.maxHeaderBytes { throw ParseError.headersTooLarge }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ParseError.malformed }
            if let existing = headers[name] { headers[name] = existing + ", " + value } else { headers[name] = value }
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" { throw ParseError.unsupportedTransferEncoding }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { throw ParseError.malformed }
            length = n
        }
        if length > maxBodyBytes { throw ParseError.bodyTooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])

        let target = String(requestLine[1])
        let path: String
        let query: String?
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = String(target[target.index(after: q)...])
        } else {
            path = target
            query = nil
        }
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body, remoteAddress: remoteAddress)
    }
}
