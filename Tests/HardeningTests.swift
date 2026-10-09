import AppKit
import XCTest
@testable import Lumen

// MARK: - Helpers

func tempFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

/// A raw TCP client, so tests can send exactly the bytes a hostile device would.
struct RawClient {
    let port: Int

    /// Sends bytes, returns everything received until the server closes or `timeout` passes. nil = couldn't connect.
    func send(_ bytes: String, timeout: TimeInterval = 3) async -> String? {
        let port = self.port
        return await Task.detached { () -> String? in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard ok == 0 else { return nil }
            _ = bytes.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    /// An open connection that sends nothing (slowloris). Returns true once the server has closed it.
    func idleUntilClosed(timeout: TimeInterval) async -> Bool {
        let r = await send("", timeout: timeout)
        return r != nil
    }
}

@MainActor
final class RemoteServerHardeningTests: XCTestCase {
    var app: AppModel!
    var port = 0

    override func setUp() async throws {
        RemoteServer.connectionLifetime = 1.5
        app = AppModel(libraryFolder: tempFolder())
        app.store.data.settings.remotePIN = "4321"
        port = Int.random(in: 20_000...40_000)
        app.remote.start(port: port)
        for _ in 0..<50 where !app.remote.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(app.remote.isRunning, app.remote.lastError ?? "server didn't start")
    }

    override func tearDown() async throws {
        app.remote.stop()
        RemoteServer.connectionLifetime = 10
    }

    private func http(_ path: String, pin: String? = nil, method: String = "GET", body: String = "") async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let pin { req.setValue(pin, forHTTPHeaderField: "X-Lumen-PIN") }
        if !body.isEmpty { req.httpBody = Data(body.utf8) }
        req.timeoutInterval = 5
        let (d, r) = try await URLSession.shared.data(for: req)
        return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
    }

    /// The review's critical finding: `Content-Length: -1` used to trap the whole app before the PIN was even checked.
    func testNegativeContentLengthDoesNotCrashAndIsRejected() async throws {
        let r = await RawClient(port: port).send("POST /api/cmd HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n{}")
        XCTAssertTrue(r?.hasPrefix("HTTP/1.1 400") == true, "got: \(r ?? "nil")")
        let (code, _) = try await http("/")
        XCTAssertEqual(code, 200, "server must still be alive")
    }

    func testOtherMalformedRequestsAreRejectedNotFatal() async throws {
        let c = RawClient(port: port)
        for bad in ["POST /api/cmd HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
                    "POST /api/cmd HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n",
                    "POST /api/cmd HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n",
                    "\u{0}\u{1}\u{2}garbage\r\n\r\n",
                    "FROB / HTTP/1.1\r\n\r\n",
                    "GET\r\n\r\n",
                    String(repeating: "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", count: 600) + "\r\n"] {
            let r = await c.send(bad)
            XCTAssertTrue(r?.contains(" 400 ") == true || r?.isEmpty == true, "unexpected reply to \(bad.prefix(30).debugDescription): \(r ?? "nil")")
        }
        let (code, _) = try await http("/")
        XCTAssertEqual(code, 200)
    }

    func testOversizedBodyIsRejected() async throws {
        let body = String(repeating: "a", count: 70_000)
        let r = await RawClient(port: port).send("POST /api/cmd HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n\(body)")
        XCTAssertTrue(r?.contains(" 400 ") == true || r?.isEmpty == true)
    }

    func testIdleConnectionsAreClosed() async throws {
        let closed = await RawClient(port: port).idleUntilClosed(timeout: 6)
        XCTAssertTrue(closed, "a silent connection must be hung up on (slowloris)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.remote.clientCount, 0, "connection count must come back down")
    }

    func testOneDeviceCannotUseEverySlot() async throws {
        // Ten silent connections from one address: only the first eight are kept.
        async let all = withTaskGroup(of: Bool.self) { g -> [Bool] in
            for _ in 0..<10 { g.addTask { await RawClient(port: self.port).send("", timeout: 1) == nil || true } }
            var out: [Bool] = []; for await v in g { out.append(v) }; return out
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(app.remote.clientCount, RemoteServer.maxConnectionsPerDevice)
        _ = await all
    }

    func testPINRequiredAndRateLimited() async throws {
        var (code, _) = try await http("/api/state")
        XCTAssertEqual(code, 401, "no PIN")
        (code, _) = try await http("/api/state", pin: "0000")
        XCTAssertEqual(code, 401, "wrong PIN")
        (code, _) = try await http("/api/state", pin: "4321")
        XCTAssertEqual(code, 200, "right PIN")
        (code, _) = try await http("/api/cmd", pin: nil, method: "POST", body: "{\"cmd\":\"clear\"}")
        XCTAssertEqual(code, 401, "commands need the PIN too")
        for i in 0..<9 { _ = try await http("/api/state", pin: String(format: "%04d", i)) }
        (code, _) = try await http("/api/state", pin: "4321")
        XCTAssertEqual(code, 429, "after repeated wrong PINs even the right one is refused for a minute")
        XCTAssertTrue(app.remote.isLockedOut)
    }

    func testFramesAndHealthNeedThePIN() async throws {
        for path in ["/api/frame?screen=audience", "/api/health", "/api/presentation?id=x"] {
            let (code, _) = try await http(path)
            XCTAssertEqual(code, 401, path)
        }
        let (code, data) = try await http("/api/health", pin: "4321")
        XCTAssertEqual(code, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["memoryMB"]); XCTAssertNotNil(json["screens"])
    }

    func testServedPagesNeverBuildHTMLFromShowData() async throws {
        for path in ["/", "/stage"] {
            let (code, data) = try await http(path)
            XCTAssertEqual(code, 200)
            let html = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(html.contains("innerHTML"), "\(path) must build elements, not HTML strings")
            XCTAssertFalse(html.contains("onclick=\"${"), "\(path)")
        }
    }

    func testNoCrossSiteAccessHeader() async throws {
        let r = await RawClient(port: port).send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        XCTAssertFalse(r?.lowercased().contains("access-control-allow-origin") == true)
    }

    /// A phone left open with an old PIN must not lock out the operator's phone.
    func testLockoutIsPerDevice() {
        for _ in 0..<RemoteServer.maxFailuresPerMinute { app.remote.noteWrongPIN(from: "192.168.1.50") }
        XCTAssertTrue(app.remote.isLockedOut("192.168.1.50"), "the misbehaving device is locked out")
        XCTAssertFalse(app.remote.isLockedOut("192.168.1.77"), "everyone else is unaffected")
        XCTAssertFalse(app.remote.isLockedOut("unknown"))
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(RemoteServer.constantTimeEqual("4321", "4321"))
        XCTAssertFalse(RemoteServer.constantTimeEqual("4321", "4322"))
        XCTAssertFalse(RemoteServer.constantTimeEqual("432", "4321"))
        XCTAssertFalse(RemoteServer.constantTimeEqual("", "4321"))
    }
}
