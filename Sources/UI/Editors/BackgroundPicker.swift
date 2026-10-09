import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

extension MediaRef {
    /// Builds a reference for a file the user picked, copying it into the library and applying the default fit rule.
    @MainActor
    static func fromFile(_ url: URL, store: LibraryStore, loop: Bool = true) -> MediaRef {
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: MediaKind = type?.conforms(to: .image) == true ? .image : type?.conforms(to: .audio) == true ? .audio : .video
        return MediaRef(kind: kind, location: store.importMedia(url).path, name: url.deletingPathExtension().lastPathComponent,
                        loop: loop, scale: store.defaultMediaScale)
    }
}

/// Chooses an image or a looping video, and how it sits on a screen that's a different shape.
struct BackgroundPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var media: MediaRef?
    var emptyLabel = "None (solid color)"

    var body: some View {
        HStack {
            if let m = media {
                BackdropThumb(media: m).frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.displayName).lineLimit(1)
                    Text(m.kind == .video ? "Looping video" : "Image").font(.caption).foregroundStyle(.secondary)
                }
                Picker("", selection: Binding(get: { m.scale }, set: { media?.scale = $0 })) {
                    Text("Fit (black bars)").tag(ScaleMode.fit)
                    Text("Fill (crop)").tag(ScaleMode.fill)
                    Text("Stretch").tag(ScaleMode.stretch)
                }
                .labelsHidden().fixedSize()
                .help("How it's placed when it isn't the same shape as the screen")
            } else {
                Text(emptyLabel).foregroundStyle(.secondary)
            }
            Spacer()
            Button(media == nil ? "Choose…" : "Change…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image, .movie]
                guard panel.runModal() == .OK, let u = panel.url else { return }
                media = MediaRef.fromFile(u, store: app.store)
            }
            if media != nil { Button("Remove") { media = nil } }
        }
    }
}

/// Small preview of an image, or a poster frame for a video.
struct BackdropThumb: View {
    var media: MediaRef
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if media.kind == .image, let img = ThumbnailCache.shared.image(media.location) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: media.scale == .fill ? .fill : .fit)
            } else if media.kind == .video {
                if let poster { Image(nsImage: poster).resizable().aspectRatio(contentMode: media.scale == .fill ? .fill : .fit) }
                Image(systemName: "film").foregroundStyle(.white.opacity(0.7)).padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .task(id: media.location) {
            guard media.kind == .video else { return }
            poster = await ThumbnailCache.shared.poster(media.location)
        }
    }
}

extension ThumbnailCache {
    private static let posters = NSCache<NSString, NSImage>()

    /// A frame from the first second of a video, generated off the main thread and cached.
    func poster(_ path: String) async -> NSImage? {
        if let c = Self.posters.object(forKey: path as NSString) { return c }
        let img: NSImage? = await Task.detached(priority: .utility) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 270)
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
                    ?? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        if let img { Self.posters.setObject(img, forKey: path as NSString) }
        return img
    }
}
