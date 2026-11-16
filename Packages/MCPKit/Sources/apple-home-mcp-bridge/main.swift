// apple-home-mcp-bridge: stdio <-> streamable-HTTP bridge for MCP clients that only speak stdio.
//
// Reads newline-delimited JSON-RPC messages on stdin, POSTs each one to the Apple Home MCP
// endpoint, and writes responses to stdout. The API key is taken from APPLE_HOME_MCP_API_KEY
// or, if unset, from the login Keychain item the menu bar app created.
//
//   apple-home-mcp-bridge [--url http://127.0.0.1:8737/mcp]

import Foundation
import MCPKit

var url = URL(string: ProcessInfo.processInfo.environment["APPLE_HOME_MCP_URL"] ?? "http://127.0.0.1:8737/mcp")!
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--url":
        guard let v = args.popFirst(), let u = URL(string: v) else { FileHandle.standardError.write(Data("--url needs a value\n".utf8)); exit(2) }
        url = u
    case "-h", "--help":
        print("usage: apple-home-mcp-bridge [--url http://127.0.0.1:8737/mcp]\nAPI key: $APPLE_HOME_MCP_API_KEY or the Keychain item 'apple-home-mcp'.")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
    }
}

let apiKey = ProcessInfo.processInfo.environment["APPLE_HOME_MCP_API_KEY"] ?? Keychain.read(Keychain.apiKeyAccount)
let stdout = FileHandle.standardOutput
let outLock = NSLock()
var sessionID: String?

func emit(_ data: Data) {
    outLock.lock(); defer { outLock.unlock() }
    stdout.write(data)
    stdout.write(Data("\n".utf8))
}

func forward(_ line: Data) async {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = line
    req.timeoutInterval = 600
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    let id = (try? JSONValue.parse(line))?["id"] ?? .null
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        if http?.statusCode == 202 || data.isEmpty { return }
        if http?.statusCode == 200 {
            emit(data)
        } else if id != .null {
            let msg = String(decoding: data, as: UTF8.self)
            emit(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string("HTTP \(http?.statusCode ?? 0): \(msg)")]]).serialized())
        }
    } catch {
        if id != .null {
            emit(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string("Apple Home MCP unreachable at \(url.absoluteString): \(error.localizedDescription). Is the menu bar app running?")]]).serialized())
        }
    }
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            await forward(Data(trimmed.utf8))
        }
    } catch {}
    done.signal()
}
done.wait()
