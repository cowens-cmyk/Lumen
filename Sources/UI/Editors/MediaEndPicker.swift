import SwiftUI

/// The common things people want a video to do when it finishes. "Custom" runs any list of actions.
enum MediaEndChoice: String, CaseIterable, Identifiable {
    case stay, loop, next, clear, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stay: "Stay on the last frame"
        case .loop: "Loop (play again)"
        case .next: "Go to the next slide"
        case .clear: "Clear the screen"
        case .custom: "Run custom actions…"
        }
    }

    static func of(_ m: MediaRef) -> MediaEndChoice {
        if m.loop { return .loop }
        switch m.onEnd ?? [] {
        case []: return .stay
        case [.nextSlide]: return .next
        case [.clear(.all)]: return .clear
        default: return .custom
        }
    }

    func apply(to m: inout MediaRef) {
        switch self {
        case .stay: m.loop = false; m.onEnd = nil
        case .loop: m.loop = true; m.onEnd = nil
        case .next: m.loop = false; m.onEnd = [.nextSlide]
        case .clear: m.loop = false; m.onEnd = [.clear(.all)]
        case .custom: m.loop = false; if (m.onEnd ?? []).isEmpty { m.onEnd = [.nextSlide] }
        }
    }
}

struct MediaEndPicker: View {
    @Binding var media: MediaRef
    var allowCustom = true

    var body: some View {
        Picker("When the video ends", selection: Binding(
            get: { MediaEndChoice.of(media) },
            set: { var m = media; $0.apply(to: &m); media = m })) {
            ForEach(MediaEndChoice.allCases.filter { allowCustom || $0 != .custom }) { Text($0.title).tag($0) }
        }
        .help("Example: after a countdown video, go to the next slide so the first song starts by itself.")
    }
}
