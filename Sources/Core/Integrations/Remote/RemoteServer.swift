import Foundation
import Network
import Observation

/// Tiny HTTP server for the phone/tablet remote and the browser-based stage display.
@MainActor
@Observable
final class RemoteServer {
    private(set) var isRunning = false
    private(set) var port: Int = 0
    private(set) var lastError: String?
    private(set) var clientCount = 0

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let queue = DispatchQueue(label: "lumen.remote")

    var urls: [String] {
        Self.localIPv4Addresses().map { "http://\($0):\(port)" }
    }

    func start(port: Int) {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true; self?.lastError = nil
                    case .failed(let e): self?.isRunning = false; self?.lastError = e.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            self.port = port
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ conn: NWConnection) {
        clientCount += 1
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    nonisolated private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                Task { @MainActor in
                    let resp = self.handle(req)
                    conn.send(content: resp.encoded(), completion: .contentProcessed { _ in conn.cancel() })
                }
            } else if done || error != nil || buf.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    // MARK: - Routing

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard let pin = app?.store.data.settings.remotePIN, !pin.isEmpty else { return true }
        return req.headers["x-lumen-pin"] == pin || req.query["pin"] == pin
    }

    private func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard let app else { return .text("Not ready", status: 503) }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/remote"):
            return .html(RemotePages.remote)
        case ("GET", "/stage"):
            return .html(RemotePages.stage)
        case ("GET", "/api/stage"):
            return .json(RemoteAPI.stage(app))
        case ("GET", "/api/state"):
            guard authorized(req) else { return .json(["error": "pin"], status: 401) }
            return .json(RemoteAPI.state(app))
        case ("GET", "/api/presentation"):
            guard authorized(req) else { return .json(["error": "pin"], status: 401) }
            guard let id = req.query["id"].flatMap(UUID.init(uuidString:)) else { return .json(["error": "id"], status: 400) }
            return .json(RemoteAPI.presentation(app, id))
        case ("POST", "/api/cmd"):
            guard authorized(req) else { return .json(["error": "pin"], status: 401) }
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            RemoteAPI.command(app, body)
            return .json(["ok": true])
        default:
            return .text("Not found", status: 404)
        }
    }

    static func localIPv4Addresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        let target = String(parts[1])
        var hs: [String: String] = [:]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") {
                hs[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        headers = hs
        let len = Int(hs["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= len else { return nil }
        body = data[bodyStart..<(bodyStart + len)]
        let comps = URLComponents(string: target)
        path = comps?.path ?? target
        query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func html(_ s: String) -> HTTPResponse { HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(s.utf8)) }
    static func text(_ s: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8)) }
    static func json(_ o: Any, status: Int = 200) -> HTTPResponse {
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: d)
    }

    func encoded() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        return Data(head.utf8) + body
    }
}

@MainActor
enum RemoteAPI {
    static func slideJSON(_ s: SlideRef) -> [String: Any] {
        ["text": s.slide.text, "group": s.groupName, "color": s.groupColor.hex, "label": s.slide.label]
    }

    static func state(_ app: AppModel) -> [String: Any] {
        let e = app.engine
        let d = app.store.data
        var live: [String: Any] = ["index": e.liveIndex ?? -1, "cleared": e.slideCleared]
        if let p = e.livePresentation {
            live["id"] = p.id.uuidString
            live["name"] = p.name
            live["slides"] = p.orderedSlides.map(slideJSON)
        }
        let playlists: [[String: Any]] = d.playlists.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }.map { pl in
            ["id": pl.id.uuidString, "name": pl.name, "items": pl.items.map { item -> [String: Any] in
                switch item.kind {
                case .header(let t): return ["type": "header", "name": t]
                case .placeholder(let t): return ["type": "placeholder", "name": t]
                case .presentation(let id):
                    return ["type": "presentation", "id": id.uuidString, "name": app.engine.presentation(id)?.name ?? "Missing"]
                }
            }]
        }
        return [
            "live": live,
            "lookID": e.lookID?.uuidString ?? "",
            "looks": d.looks.map { ["id": $0.id.uuidString, "name": $0.name] },
            "macros": d.macros.map { ["id": $0.id.uuidString, "name": $0.name, "color": $0.color.hex] },
            "props": d.props.map { ["id": $0.id.uuidString, "name": $0.name, "active": e.activeProps[$0.id] != nil] },
            "timers": d.timers.map { ["id": $0.id.uuidString, "name": $0.name, "value": e.timerValue($0.id),
                                      "running": e.timers[$0.id]?.running ?? false] },
            "playlists": playlists,
            "message": e.message ?? "",
            "volunteer": app.volunteerMode,
        ]
    }

    static func presentation(_ app: AppModel, _ id: UUID) -> [String: Any] {
        guard let p = app.engine.presentation(id) else { return ["error": "missing"] }
        return ["id": p.id.uuidString, "name": p.name, "slides": p.orderedSlides.map(slideJSON)]
    }

    static func stage(_ app: AppModel) -> [String: Any] {
        guard let screen = app.store.data.screens.first(where: { $0.role == .stage }) ?? app.store.data.screens.first else { return [:] }
        let s = app.outputs.stageSnapshot(for: screen)
        let style = s.layout.chordStyle ?? .nashville
        func chordLines(_ text: String, _ chords: [ChordPlacement]) -> [[[String: String]]] {
            guard s.layout.showChords != false, !chords.isEmpty else { return [] }
            return text.components(separatedBy: "\n").enumerated().map { i, line in
                ChordLayout.segments(line: line, chords: chords.filter { $0.line == i }).map {
                    ["c": $0.chord.map { ChordLayout.label($0, key: s.key, style: style) } ?? "", "t": $0.text]
                }
            }
        }
        return ["current": s.current, "currentChords": chordLines(s.current, s.currentChords),
                "nextChordLines": chordLines(s.next, s.nextChords), "key": s.key ?? "", "next": s.next, "nextGroup": s.nextGroup, "clock": s.clock, "notes": s.notes,
                "message": s.message ?? "", "timers": s.timers.map { ["name": $0.0, "value": $0.1] }]
    }

    static func command(_ app: AppModel, _ b: [String: Any]) {
        let e = app.engine
        func uuid(_ k: String) -> UUID? { (b[k] as? String).flatMap(UUID.init(uuidString:)) }
        switch b["cmd"] as? String {
        case "next": e.next()
        case "prev": e.previous()
        case "trigger":
            if let id = uuid("id") { e.trigger(presentationID: id, index: b["index"] as? Int ?? 0, playlistID: uuid("playlist")) }
        case "clear":
            e.clear(ClearTarget(rawValue: b["target"] as? String ?? "all") ?? .all)
        case "look":
            if let id = uuid("id") { e.setLook(id) }
        case "macro":
            if let id = uuid("id") { e.runMacro(id) }
        case "prop":
            if let id = uuid("id") { e.toggleProp(id) }
        case "message":
            e.showMessage(b["text"] as? String)
        case "stageMessage":
            e.setStageMessage(b["text"] as? String)
        case "timer":
            guard let id = uuid("id") else { return }
            switch b["action"] as? String {
            case "start": e.startTimer(id)
            case "stop": e.stopTimer(id)
            case "reset": e.resetTimer(id)
            default: break
            }
        default: break
        }
    }
}
