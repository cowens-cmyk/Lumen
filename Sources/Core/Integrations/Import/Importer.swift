import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case keynoteMissing, keynoteFailed(String), unsupported(String), empty
    var errorDescription: String? {
        switch self {
        case .keynoteMissing: "Keynote is needed to import PowerPoint and Keynote files. Install it free from the App Store, or export the deck as PDF."
        case .keynoteFailed(let s): "Keynote couldn't export the slides: \(s)"
        case .unsupported(let s): "Lumen can't import .\(s) files yet."
        case .empty: "Nothing was found to import."
        }
    }
}

@MainActor
struct Importer {
    let store: LibraryStore

    static let allowedTypes: [UTType] = [
        .image, .movie, .audio, .pdf, .plainText, .xml,
        UTType(filenameExtension: "key") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "ppt") ?? .data,
        UTType(filenameExtension: "usr") ?? .data,
        UTType(filenameExtension: "cho") ?? .data,
        UTType(filenameExtension: "chordpro") ?? .data,
    ]

    /// Imports any supported file(s) and returns created presentations.
    struct Outcome { var presentations: [Presentation] = []; var failures: [String] = [] }

    /// Imports every file it can; a bad file is reported and skipped, never discarding the rest of the batch.
    func importFiles(_ urls: [URL]) async throws -> Outcome {
        var out: [Presentation] = []
        var failures: [String] = []
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !images.isEmpty { out.append(imagePresentation(images)) }
        for url in urls where !images.contains(url) {
          do {
            let ext = url.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            if type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true {
                out.append(mediaPresentation(url, kind: type?.conforms(to: .audio) == true ? .audio : .video))
            } else if ["cho", "chordpro", "crd"].contains(ext) || (ext == "pdf" && ChordChartReader.looksLikeChart(url: url)) {
                // A chord chart becomes a song: lyrics, song order, key and chords, ready for the stage display.
                out.append(try songFromChart(url))
            } else if ext == "pdf" {
                out.append(try pdfPresentation(url))
            } else if ["key", "pptx", "ppt"].contains(ext) {
                out.append(try await keynotePresentation(url))
            } else if ext == "usr" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let r = LyricParser.parseUSR(text)
                var p = LyricParser.presentation(name: r.title, text: r.lyrics, maxLines: maxLines)
                p.author = r.author; p.copyright = r.copyright; p.ccli = r.ccli
                out.append(p)
            } else if ext == "xml" {
                let data = try Data(contentsOf: url)
                guard let r = LyricParser.parseOpenLyrics(data) else { throw ImportError.unsupported(ext) }
                var p = LyricParser.presentation(name: r.title, text: r.lyrics, maxLines: maxLines)
                p.arrangement = LyricParser.arrangement(from: r.order, groups: p.groups)
                out.append(p)
            } else if ext == "txt" || type?.conforms(to: .plainText) == true {
                let text = try String(contentsOf: url, encoding: .utf8)
                let r = LyricParser.parseTXT(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
                var p = LyricParser.presentation(name: r.title, text: r.lyrics, maxLines: maxLines)
                p.ccli = r.ccli
                out.append(p)
            } else {
                throw ImportError.unsupported(ext)
            }
          } catch {
            failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
          }
        }
        if out.isEmpty, let first = failures.first, urls.count == failures.count { throw ImportError.keynoteFailed(first) }
        out.forEach(store.upsert)
        return Outcome(presentations: out, failures: failures)
    }

    /// Builds a whole song from a chord chart: slides from its lyrics, the song order, the key and the chords.
    func songFromChart(_ url: URL) throws -> Presentation {
        let chart = try ChordChartReader.read(url: url)
        var p = Presentation(name: "", kind: .song)
        ChordMatcher.apply(chart, to: &p, maxLines: maxLines)
        if p.name.isEmpty { p.name = chart.title.isEmpty ? url.deletingPathExtension().lastPathComponent : chart.title }
        return p
    }

    private var maxLines: Int { store.resolvedTheme(for: Presentation(name: "", kind: .song)).maxLinesPerSlide }

    func imagePresentation(_ urls: [URL], name: String? = nil) -> Presentation {
        var p = Presentation(name: name ?? (urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Images"), kind: .media)
        let slides = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { u in
            let local = store.importMedia(u)
            return Slide(media: MediaRef(kind: .image, location: local.path, name: u.deletingPathExtension().lastPathComponent, scale: store.defaultMediaScale))
        }
        p.groups = [SlideGroup(name: "Slides", color: RGBA(hex: "#64748B"), slides: slides)]
        p.slideshow = SlideshowSettings(enabled: false, interval: 8, loop: true)
        return p
    }

    func mediaPresentation(_ url: URL, kind: MediaKind) -> Presentation {
        let local = store.importMedia(url)
        var p = Presentation(name: url.deletingPathExtension().lastPathComponent, kind: .media)
        p.groups = [SlideGroup(name: kind == .audio ? "Audio" : "Video", color: RGBA(hex: "#64748B"),
                               slides: [Slide(media: MediaRef(kind: kind, location: local.path, loop: false, scale: store.defaultMediaScale))])]
        return p
    }

    func pdfPresentation(_ url: URL) throws -> Presentation {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw ImportError.empty }
        let folder = store.mediaFolder.appendingPathComponent("pdf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1920 / max(bounds.width, 1)
            let img = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            let dest = folder.appendingPathComponent(String(format: "slide-%03d.png", i + 1))
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dest)
                images.append(dest)
            }
        }
        return slidesFromExportedImages(images, name: url.deletingPathExtension().lastPathComponent)
    }

    private func slidesFromExportedImages(_ images: [URL], name: String) -> Presentation {
        var p = Presentation(name: name, kind: .generic)
        p.groups = [SlideGroup(name: "Slides", color: RGBA(hex: "#64748B"), slides: images.map {
            Slide(media: MediaRef(kind: .image, location: $0.path, scale: .fit))
        })]
        return p
    }

    /// Uses Keynote to export .key / .pptx / .ppt to PNGs (most faithful rendering available on a Mac).
    func keynotePresentation(_ url: URL) async throws -> Presentation {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil else {
            throw ImportError.keynoteMissing
        }
        let folder = store.mediaFolder.appendingPathComponent("deck-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = """
        set srcFile to POSIX file "\(url.path.replacingOccurrences(of: "\"", with: "\\\""))"
        set outFolder to POSIX file "\(folder.path)"
        tell application "Keynote"
            set theDoc to open srcFile
            delay 1
            export theDoc to outFolder as slide images with properties {image format:PNG, skipped slides:false}
            close theDoc saving no
        end tell
        """
        let result: String? = await Task.detached {
            var err: NSDictionary?
            let s = NSAppleScript(source: script)
            s?.executeAndReturnError(&err)
            return err.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
        }.value
        if let result { throw ImportError.keynoteFailed(result) }
        // Keynote writes into a subfolder named after the document in some versions.
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) } ?? []
        guard !files.isEmpty else { throw ImportError.empty }
        let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return slidesFromExportedImages(sorted, name: url.deletingPathExtension().lastPathComponent)
    }
}
