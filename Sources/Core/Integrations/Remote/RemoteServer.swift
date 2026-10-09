import CoreImage
import Foundation
import Network
import AppKit
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

    /// Hard limits so a stray or hostile client on the network can't wedge or crash the show.
    static let maxConnections = 48
    static let maxConnectionsPerDevice = 8
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024
    /// Seconds a connection may stay open. (A variable so tests can shorten it.)
    nonisolated(unsafe) static var connectionLifetime: TimeInterval = 10
    @ObservationIgnored private var perDevice: [String: Int] = [:]

    private func accept(_ conn: NWConnection) {
        // One device can't use up every slot: a phone keeps working while something else misbehaves.
        var device = "unknown"
        if case .hostPort(let host, _) = conn.endpoint { device = "\(host)" }
        guard clientCount < Self.maxConnections, perDevice[device, default: 0] < Self.maxConnectionsPerDevice else { conn.cancel(); return }
        clientCount += 1
        perDevice[device, default: 0] += 1
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in
                    guard let self else { return }
                    self.clientCount = max(0, self.clientCount - 1)
                    self.perDevice[device] = max(0, (self.perDevice[device] ?? 1) - 1)
                }
            default: break
            }
        }
        conn.start(queue: queue)
        // A real request arrives in milliseconds; never hold a socket open longer than this (slowloris).
        queue.asyncAfter(deadline: .now() + Self.connectionLifetime) { conn.cancel() }
        receive(conn, buffer: Data())
    }

    nonisolated private func receive(_ conn: NWConnection, buffer: Data) {
        var device = "unknown"
        if case .hostPort(let host, _) = conn.endpoint { device = "\(host)" }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            func reply(_ r: HTTPResponse) {
                conn.send(content: r.encoded(), completion: .contentProcessed { _ in conn.cancel() })
            }
            switch HTTPRequest.parse(buf) {
            case .request(let req):
                Task { @MainActor in reply(self.handle(req, device: device)) }
            case .invalid:
                reply(.text("Bad request", status: 400))
            case .incomplete:
                if done || error != nil { conn.cancel() }
                else if buf.count > Self.maxHeaderBytes + Self.maxBodyBytes { reply(.text("Too large", status: 413)) }
                else { self.receive(conn, buffer: buf) }
            }
        }
    }

    // MARK: - Routing

    /// Wrong-PIN attempts in the last minute, across all clients. Past the limit every control request is
    /// refused (429) until the minute is up, so a 4-digit PIN can't be guessed from the congregation's Wi-Fi.
    /// Counted per device (by address), so a phone left open with an old PIN can't lock the operator's phone out.
    @ObservationIgnored private var failures: [String: [Date]] = [:]
    static let maxFailuresPerMinute = 8

    func isLockedOut(_ device: String = "unknown") -> Bool {
        let recent = (failures[device] ?? []).filter { Date().timeIntervalSince($0) <= 60 }
        failures[device] = recent.isEmpty ? nil : recent
        return recent.count >= Self.maxFailuresPerMinute
    }

    /// True if any device is currently locked out (for tests and the settings page).
    var isLockedOut: Bool { failures.keys.contains { isLockedOut($0) } }

    /// With no PIN set the remote is open (only for deliberate use); the app generates one on first launch.
    private func authorized(_ req: HTTPRequest, device: String) -> Bool {
        guard let pin = app?.store.data.settings.remotePIN, !pin.isEmpty else { return true }
        let given = req.headers["x-lumen-pin"] ?? req.query["pin"] ?? ""
        if Self.constantTimeEqual(given, pin) { return true }
        if !given.isEmpty { noteWrongPIN(from: device) }   // an empty attempt is just the page asking whether a PIN is needed
        return false
    }

    func noteWrongPIN(from device: String) { failures[device, default: []].append(Date()) }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return diff == 0
    }

    @ObservationIgnored private var frameCache: [String: (at: Date, png: Data)] = [:]

    /// PNG encoding is main-thread work; reuse the last encode for half a second so polling can't stall the operator UI.
    private func cachedFrame(role: ScreenRole, buffer: CVPixelBuffer, width: Int) -> Data? {
        let key = "\(role.rawValue)-\(width)"
        if let c = frameCache[key], Date().timeIntervalSince(c.at) < 0.5 { return c.png }
        guard let png = RemoteAPI.png(buffer, width: width) else { return nil }
        frameCache[key] = (Date(), png)
        return png
    }

    private func handle(_ req: HTTPRequest, device: String) -> HTTPResponse {
        guard let app else { return .text("Not ready", status: 503) }
        if req.path.hasPrefix("/api/"), req.path != "/api/stage", isLockedOut(device) {
            return HTTPResponse(status: 429, contentType: "application/json", body: Data("{\"error\":\"too many wrong PINs; wait a minute\"}".utf8))
        }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/remote"):
            return .html(RemotePages.remote)
        case ("GET", "/stage"):
            return .html(RemotePages.stage)
        case ("GET", "/api/frame"):
            // PNG of what a screen is showing right now: ?screen=audience|stream|stage (&w=960 to shrink).
            guard authorized(req, device: device) else { return .json(["error": "pin"], status: 401) }
            let role = ScreenRole(rawValue: req.query["screen"] ?? "audience") ?? .audience
            guard let screen = app.store.data.screens.first(where: { $0.role == role }),
                  let buffer = app.outputs.renderers[screen.id]?.latestFrame,
                  let png = cachedFrame(role: role, buffer: buffer, width: min(1280, max(160, Int(req.query["w"] ?? "") ?? 960))) else {
                return .text("No frame", status: 404)
            }
            return HTTPResponse(status: 200, contentType: "image/png", body: png)
        case ("GET", "/api/health"):
            guard authorized(req, device: device) else { return .json(["error": "pin"], status: 401) }
            return .json(RemoteAPI.health(app))
        case ("GET", "/api/stage"):
            return .json(RemoteAPI.stage(app))
        case ("GET", "/api/state"):
            guard authorized(req, device: device) else { return .json(["error": "pin"], status: 401) }
            return .json(RemoteAPI.state(app))
        case ("GET", "/api/presentation"):
            guard authorized(req, device: device) else { return .json(["error": "pin"], status: 401) }
            guard let id = req.query["id"].flatMap(UUID.init(uuidString:)) else { return .json(["error": "id"], status: 400) }
            return .json(RemoteAPI.presentation(app, id))
        case ("POST", "/api/cmd"):
            guard authorized(req, device: device) else { return .json(["error": "pin"], status: 401) }
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

    enum Parsed {
        case incomplete          // keep reading
        case invalid             // malformed or over a limit: answer 400 and hang up
        case request(HTTPRequest)
    }

    private init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    /// Parses a request defensively: nothing a client sends may trap. Negative, non-numeric or oversized
    /// Content-Length, bad UTF-8 and oversized headers are all `.invalid`.
    static func parse(_ data: Data) -> Parsed {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > RemoteServer.maxHeaderBytes ? .invalid : .incomplete
        }
        guard sep.lowerBound <= RemoteServer.maxHeaderBytes else { return .invalid }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, ["GET", "POST", "HEAD", "OPTIONS"].contains(String(parts[0])) else { return .invalid }
        var hs: [String: String] = [:]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") {
                hs[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var len = 0
        if let raw = hs["content-length"] {
            guard let n = Int(raw), n >= 0, n <= RemoteServer.maxBodyBytes else { return .invalid }
            len = n
        }
        let bodyStart = sep.upperBound
        let available = data.count - bodyStart
        guard available >= len else { return .incomplete }
        let comps = URLComponents(string: String(parts[1]))
        return .request(HTTPRequest(
            method: String(parts[0]), path: comps?.path ?? String(parts[1]),
            query: Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }),
            headers: hs, body: Data(data[bodyStart..<(bodyStart + len)])))
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
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8) + body
    }
}

@MainActor
enum RemoteAPI {
    static func png(_ buffer: CVPixelBuffer, width: Int) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let scale = CGFloat(max(64, min(width, 3840))) / image.extent.width
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = ScreenRenderer.sharedContext.createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

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

    static func health(_ app: AppModel) -> [String: Any] {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        let screens: [[String: Any]] = app.store.data.screens.filter(\.enabled).map { s in
            let h = app.outputs.renderers[s.id]?.health
            return ["name": s.name, "role": s.role.rawValue, "fps": h?.fps ?? 0, "targetFPS": h?.targetFPS ?? 0, "avgMs": h?.avgMs ?? 0,
                    "maxMs": h?.maxMs ?? 0, "lateFrames": h?.lateFrames ?? 0, "frames": h?.totalFrames ?? 0, "healthy": h?.isHealthy ?? false,
                    "status": app.outputs.statusByScreen[s.id] ?? []]
        }
        return ["version": UpdateManager.currentVersion, "memoryMB": kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1,
                "threads": Thread.isMultiThreaded() ? 1 : 0, "keptAwake": AppModel.keepAwakeEnabled, "screens": screens,
                "live": app.engine.currentSlide != nil, "outputsEnabled": app.outputs.outputsEnabled,
                "pco": ["lastSync": app.pco.lastSync?.description ?? "never", "error": app.pco.lastError ?? ""]]
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
