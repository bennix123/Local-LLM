import Foundation
import Network

// A minimal HTTP/1.1 server over Network.framework — no external dependencies.
// Enough for a localhost single-user app: reads one request per connection
// (Connection: close), supports binary bodies (PDF/CSV upload) via Content-Length.

struct HTTPRequest {
    let method: String
    let path: String            // path only, query stripped
    let query: [String: String]
    let headers: [String: String]  // lowercased keys
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ status: Int = 200, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
    }
    static func text(_ status: Int, _ s: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
    }
    static func html(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200,
                     headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: data)
    }
}

private let statusText: [Int: String] = [
    200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request",
    404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error",
]

final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "penny.http", attributes: .concurrent)

    init(port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    // Accumulate bytes until we have the full head + Content-Length body.
    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk, !chunk.isEmpty { buffer.append(chunk) }

            if let (headEnd, headers, requestLine) = Self.parseHead(buffer) {
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = headEnd
                let have = buffer.count - bodyStart
                if have >= contentLength {
                    let body = buffer.subdata(in: bodyStart ..< (bodyStart + contentLength))
                    let req = Self.makeRequest(requestLine: requestLine, headers: headers, body: body)
                    Task {
                        let resp = await self.handler(req)
                        self.send(conn, resp)
                    }
                    return
                }
            }

            if let error {
                _ = error
                conn.cancel(); return
            }
            if isComplete { conn.cancel(); return }
            self.receiveRequest(conn, buffer: buffer)
        }
    }

    // Returns (index just past \r\n\r\n, lowercased headers, request line) once head is complete.
    private static func parseHead(_ buffer: Data) -> (Int, [String: String], String)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: sep) else { return nil }
        let headData = buffer.subdata(in: 0 ..< r.lowerBound)
        guard let headStr = String(data: headData, encoding: .utf8) else { return nil }
        var lines = headStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        return (r.upperBound, headers, requestLine)
    }

    private static func makeRequest(requestLine: String, headers: [String: String], body: Data) -> HTTPRequest {
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let rawTarget = parts.count > 1 ? String(parts[1]) : "/"
        var path = rawTarget
        var query: [String: String] = [:]
        if let q = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<q])
            let qs = rawTarget[rawTarget.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func send(_ conn: NWConnection, _ resp: HTTPResponse) {
        var head = "HTTP/1.1 \(resp.status) \(statusText[resp.status] ?? "OK")\r\n"
        var headers = resp.headers
        headers["Content-Length"] = "\(resp.body.count)"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Headers"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
