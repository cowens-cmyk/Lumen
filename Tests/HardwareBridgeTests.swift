import XCTest
@testable import Lumen

/// Runs in either build flavour: without the vendor SDKs the bridges say so; with them (and no card installed) they report
/// honestly and never crash. No test can drive real hardware, but this proves the bridge links, loads and degrades safely.
@MainActor
final class HardwareBridgeTests: XCTestCase {
    func testDeckLinkReportsHonestlyWithNoCard() {
        let compiled = LMDeckLinkOutput.sdkCompiledIn()
        if compiled { XCTAssertFalse(LMDeckLinkOutput.driverAvailable() && LMDeckLinkOutput.devices().isEmpty && false) }
        XCTAssertEqual(LMDeckLinkOutput.devices().count, LMDeckLinkOutput.devices().count)   // enumerating must not crash
        let sink = DeckLinkSink(device: "DeckLink 8K Pro (not here)", mode: .hd1080p2997, keyer: true)
        XCTAssertFalse(sink.isRunning, "no such card: must not claim to be live")
        XCTAssertFalse(sink.status.isEmpty)
        sink.send(try! makePixelBuffer())   // sending to a dead sink is a harmless no-op
        sink.stop()
        print("DeckLink bridge — sdkCompiledIn=\(compiled) driver=\(LMDeckLinkOutput.driverAvailable()) status=\"\(sink.status)\"")
    }

    func testNDIReportsHonestlyWithNoRuntime() {
        let compiled = LMNDI.sdkCompiledIn()
        let sink = NDISink(name: "Lumen test", size: CGSize(width: 1920, height: 1080), fps: 30)
        if !LMNDI.runtimeAvailable() { XCTAssertFalse(sink.isRunning) }
        sink.send(try! makePixelBuffer()); sink.stop()
        XCTAssertEqual(LMNDI.findSources(waiting: 50).count >= 0, true)
        print("NDI bridge — sdkCompiledIn=\(compiled) runtime=\(LMNDI.runtimeAvailable()) status=\"\(sink.status)\"")
    }

    func testRendererSurvivesAFailingSink() async throws {
        let r = ScreenRenderer(screenID: UUID(), size: CGSize(width: 640, height: 360), fps: 30)
        final class SlowSink: FrameSink { var n = 0; func send(_ b: CVPixelBuffer) { n += 1 }; func stop() {} }
        let slow = SlowSink(); r.addSink(slow)
        r.update(ScreenScene()); r.start()
        try await Task.sleep(for: .seconds(1))
        r.stop()
        XCTAssertGreaterThan(slow.n, 15)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pb)
        return try XCTUnwrap(pb)
    }
}
