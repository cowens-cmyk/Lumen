import AppKit
import CoreImage
import Observation
import ScreenCaptureKit
import WebKit

/// A real browser (YouTube, Vimeo, web pages, online video) whose picture can go to any output.
/// The page lives in its own window so the operator can click/scroll it; ScreenCaptureKit
/// captures that window (even when covered by other windows) into the media layer.
@MainActor
@Observable
final class BrowserController: NSObject {
    private(set) var urlString = ""
    private(set) var title = ""
    private(set) var isCapturing = false
    private(set) var lastError: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private let output = WebStreamOutput()
    @ObservationIgnored private var titleObservation: NSKeyValueObservation?
    @ObservationIgnored private var isStarting = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: cfg)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        titleObservation = webView.observe(\.title) { [weak self] wv, _ in
            Task { @MainActor in self?.title = wv.title ?? "" }
        }
    }

    func load(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        urlString = s
        webView.load(URLRequest(url: url))
        showWindow()
        startCapture()
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1280, height: 720),
                             styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Lumen Browser Source"
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.contentView = webView
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("LumenBrowser")
            window = w
        }
        window?.orderFront(nil)
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }

    /// Common for video sites: request the page's main video to go element-fullscreen inside the web view.
    func fillWithVideo() {
        let js = """
        (function(){var v=document.querySelector('video'); if(!v) return false;
        v.style.cssText='position:fixed;inset:0;width:100vw;height:100vh;z-index:2147483647;background:#000;object-fit:contain';
        document.body.appendChild(v); v.play(); return true;})();
        """
        webView.evaluateJavaScript(js)
    }

    func startCapture() {
        guard stream == nil, !isStarting, let window else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                // A brand-new window can take a moment to show up as shareable content: look a few times before giving up.
                var found: SCWindow?
                for attempt in 0..<6 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    found = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
                    if found != nil { break }
                    try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                }
                guard let scWindow = found else {
                    lastError = "Couldn't find the browser window to capture."
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let cfg = SCStreamConfiguration()
                cfg.width = 1920
                cfg.height = 1080
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = false
                cfg.capturesAudio = false
                cfg.scalesToFit = true
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await s.startCapture()
                stream = s
                isCapturing = true
                lastError = nil
            } catch {
                lastError = "Screen Recording permission is needed to send the browser to outputs. (\(error.localizedDescription))"
            }
        }
    }

    func stopCapture() {
        let s = stream
        stream = nil
        isCapturing = false
        Task { try? await s?.stopCapture() }
        LiveFrames.shared.set(LiveFrames.webKey, nil)
    }

    func close() {
        stopCapture()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        window?.orderOut(nil)
    }
}

final class WebStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "lumen.web.capture", qos: .userInteractive)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Skip idle/blank frames ScreenCaptureKit sends when nothing changed.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        LiveFrames.shared.set(LiveFrames.webKey, CIImage(cvPixelBuffer: pb))
    }
}


extension BrowserController: SCStreamDelegate {
    /// The capture stopped on its own (display sleep, permission change, window closed). Don't pretend it's still live;
    /// try once to bring it back.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.isCapturing = false
            LiveFrames.shared.set(LiveFrames.webKey, nil)
            self.lastError = "The browser picture stopped (\(error.localizedDescription)). Restarting it…"
            try? await Task.sleep(for: .seconds(1))
            if self.window?.isVisible == true { self.startCapture() }
        }
    }
}
