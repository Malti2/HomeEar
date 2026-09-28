import Foundation
import Network

// Loopback-only MCP endpoint. The Poke CLI must expose it through its authenticated tunnel.
@MainActor final class MCPServer {
    private var listener: NWListener?
    private weak var state: AppState?
    init(state: AppState) { self.state = state }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 3000)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                switch status {
                case .ready: self?.state?.ttsState = "Local tool ready; tunnel required"
                case .failed(let error): self?.state?.ttsState = "Tool error: \(error.localizedDescription)"
                default: break
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }
    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, accumulated: Data())
    }

    // TCP is a byte stream, not a request-message stream. Neither the headers
    // nor the JSON body is guaranteed to arrive in one receive callback.
    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard error == nil else { connection.cancel(); return }
                let bytes = accumulated + (chunk ?? Data())
                guard bytes.count <= 65536 else {
                    self.send(["error": "Request too large"], code: 413, on: connection); return
                }
                self.respond(to: bytes, complete: complete, on: connection)
            }
        }
    }

    private func respond(to data: Data, complete: Bool, on connection: NWConnection) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if complete { connection.cancel() }
            else { receive(on: connection, accumulated: data) }
            return
        }
        guard let header = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            send(["error": "Invalid HTTP headers"], code: 400, on: connection); return
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        guard requestLine.hasPrefix("POST /mcp ") else {
            // The first line alone is safe to surface; never echo auth headers or body.
            let methodAndPath = requestLine.split(separator: " ").prefix(2).joined(separator: " ")
            send(["error": "Unsupported HTTP route: \(methodAndPath.prefix(120))"], code: 400, on: connection); return
        }
        guard let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(lengthLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""),
              length >= 0, length <= 32768 else {
            let chunked = lines.contains { $0.lowercased().hasPrefix("transfer-encoding:") }
            send(["error": chunked ? "Chunked transfer not supported" : "Missing or invalid Content-Length"], code: 400, on: connection); return
        }
        let available = data.distance(from: split.upperBound, to: data.endIndex)
        if available < length {
            if complete { connection.cancel() }
            else { receive(on: connection, accumulated: data) }
        } else { process(Data(data[split.upperBound...].prefix(length)), on: connection) }
    }
    private func process(_ body: Data, on connection: NWConnection) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = request["method"] as? String else {
            send(["error": "Invalid JSON-RPC"], code: 400, on: connection); return
        }
        let id = request["id"] ?? NSNull()
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "HomeEar", "version": "0.1.0"]]
        case "tools/list":
            result = ["tools": [["name": "speak", "description": "Speak a short response through the Mac's local voice", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]]]]
        case "tools/call":
            let parameters = request["params"] as? [String: Any]
            let args = parameters?["arguments"] as? [String: Any]
            if parameters?["name"] as? String == "speak", let text = args?["text"] as? String, !text.isEmpty, text.count <= 1000 {
                state?.tts.speak(text)
                result = ["content": [["type": "text", "text": "Speaking on this Mac."]]]
            } else {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Invalid speech request"]], on: connection); return
            }
        case "notifications/initialized":
            sendNoContent(on: connection); return
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]], on: connection); return
        }
        send(["jsonrpc": "2.0", "id": id, "result": result], on: connection)
    }
    private func send(_ object: [String: Any], code: Int = 200, on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { connection.cancel(); return }
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func sendNoContent(on connection: NWConnection) {
        connection.send(content: Data("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
