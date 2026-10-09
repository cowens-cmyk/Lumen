import SwiftUI

/// The design canvas every slide is laid out on; outputs scale from this.
let designSize = CGSize(width: 1920, height: 1080)

extension HAlign {
    var textAlignment: TextAlignment {
        switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    var horizontal: HorizontalAlignment {
        switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

extension VAlign {
    func alignment(_ h: HAlign) -> Alignment {
        switch (self, h) {
        case (.top, .leading): .topLeading
        case (.top, .center): .top
        case (.top, .trailing): .topTrailing
        case (.middle, .leading): .leading
        case (.middle, .center): .center
        case (.middle, .trailing): .trailing
        case (.bottom, .leading): .bottomLeading
        case (.bottom, .center): .bottom
        case (.bottom, .trailing): .bottomTrailing
        }
    }
}

extension Theme {
    func font(size: Double? = nil) -> Font {
        .custom(fontName, size: size ?? fontSize).weight(bold ? .bold : .regular)
    }
}

/// Slide text drawn on a transparent 1920x1080 canvas. The compositor draws backgrounds underneath.
struct SlideCanvas: View {
    var text: String
    var label: String
    var theme: Theme
    var mode: RenderMode

    var body: some View {
        ZStack {
            switch mode {
            case .hidden:
                Color.clear
            case .lowerThird:
                LowerThirdView(text: text, label: label, style: theme.lowerThird, fontName: theme.fontName,
                               bold: theme.bold, uppercase: theme.uppercase)
            case .fullSlide, .transparentText:
                fullText
            }
        }
        .frame(width: designSize.width, height: designSize.height)
    }

    private var displayText: String { theme.uppercase ? text.uppercased() : text }

    @ViewBuilder private var fullText: some View {
        ZStack(alignment: theme.vAlign.alignment(theme.align)) {
            Color.clear
            VStack(alignment: theme.align.horizontal, spacing: 24) {
                OutlinedText(text: displayText, theme: theme)
                if theme.showLabel, !label.isEmpty {
                    Text(label)
                        .font(.custom(theme.fontName, size: theme.labelSize))
                        .foregroundStyle(theme.labelColor.color)
                        .shadow(color: .black.opacity(theme.shadow ? 0.7 : 0), radius: 6, y: 2)
                }
            }
            .padding(theme.padding)
        }
    }
}

struct OutlinedText: View {
    var text: String
    var theme: Theme

    var body: some View {
        let base = Text(text)
            .font(theme.font())
            .multilineTextAlignment(theme.align.textAlignment)
            .lineSpacing(theme.lineSpacing)
            .minimumScaleFactor(theme.autoFit ? 0.3 : 1)
        ZStack {
            if theme.outlineWidth > 0 {
                let w = theme.outlineWidth
                ForEach(0..<8, id: \.self) { i in
                    let a = Double(i) * .pi / 4
                    base.foregroundStyle(theme.outlineColor.color).offset(x: cos(a) * w, y: sin(a) * w)
                }
            }
            base.foregroundStyle(theme.textColor.color)
        }
        .shadow(color: .black.opacity(theme.shadow ? 0.75 : 0), radius: 10, x: 0, y: 4)
    }
}

struct LowerThirdView: View {
    var text: String
    var label: String
    var style: LowerThirdStyle
    var fontName: String
    var bold: Bool
    var uppercase: Bool
    var subtitleIsLabel = true

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if style.align != .leading { Spacer(minLength: 0) }
                HStack(spacing: 0) {
                    Rectangle().fill(style.accentColor.color).frame(width: 10)
                    VStack(alignment: style.align.horizontal, spacing: 10) {
                        Text(uppercase ? text.uppercased() : text)
                            .font(.custom(fontName, size: style.fontSize).weight(bold ? .semibold : .regular))
                            .foregroundStyle(style.textColor.color)
                            .multilineTextAlignment(style.align.textAlignment)
                            .lineSpacing(4)
                            .minimumScaleFactor(0.4)
                        if style.showReference, !label.isEmpty {
                            Text(label)
                                .font(.custom(fontName, size: style.referenceSize).weight(.medium))
                                .foregroundStyle(style.accentColor.color)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: style.align.horizontal, vertical: .center))
                }
                .frame(maxHeight: designSize.height * style.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(style.barColor.color)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                if style.align != .trailing { Spacer(minLength: 0) }
            }
            .padding(.horizontal, style.sideMargin)
            .padding(.bottom, style.bottomMargin)
        }
        .frame(width: designSize.width, height: designSize.height)
    }
}

/// Props (lower thirds / graphics) plus the audience message banner.
struct OverlayCanvas: View {
    var props: [Prop]
    var message: String?
    var showProps: Bool
    var showMessage: Bool

    var body: some View {
        ZStack {
            Color.clear
            if showProps {
                ForEach(props) { p in
                    switch p.kind {
                    case .lowerThird:
                        PropLowerThird(prop: p)
                    case .image:
                        if let path = p.media?.location, let img = NSImage(contentsOfFile: path) {
                            Image(nsImage: img).resizable().scaledToFit()
                        }
                    case .text:
                        Text(p.title)
                            .font(.system(size: p.style.fontSize, weight: .bold))
                            .foregroundStyle(p.style.textColor.color)
                            .shadow(radius: 8)
                    }
                }
            }
            if showMessage, let message {
                VStack {
                    Text(message)
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 40).padding(.vertical, 18)
                        .background(Color(red: 0.75, green: 0.1, blue: 0.1).opacity(0.9), in: Capsule())
                        .padding(.top, 40)
                    Spacer()
                }
            }
        }
        .frame(width: designSize.width, height: designSize.height)
    }
}

struct PropLowerThird: View {
    var prop: Prop
    var body: some View {
        let s = prop.style
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 0) {
                    Rectangle().fill(s.accentColor.color).frame(width: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(prop.title).font(.system(size: s.fontSize, weight: .bold)).foregroundStyle(s.textColor.color)
                        if !prop.subtitle.isEmpty {
                            Text(prop.subtitle).font(.system(size: s.referenceSize, weight: .medium))
                                .foregroundStyle(s.textColor.color.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 20)
                }
                .fixedSize()
                .background(s.barColor.color)
                .clipShape(RoundedRectangle(cornerRadius: s.cornerRadius))
                Spacer()
            }
            .padding(.leading, s.sideMargin)
            .padding(.bottom, s.bottomMargin + 220)
        }
    }
}

/// A complete slide preview (background + text) for thumbnails and editors.
struct SlidePreview: View {
    var text: String
    var label: String = ""
    var theme: Theme
    var mode: RenderMode = .fullSlide
    var media: MediaRef? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if mode == .fullSlide {
                    theme.background.color
                    if let m = media ?? theme.backgroundMedia, m.kind == .image, let img = ThumbnailCache.shared.image(m.location) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: m.scale == .fit ? .fit : .fill)
                    } else if let m = media ?? theme.backgroundMedia, m.kind == .color, let c = m.color {
                        c.color
                    }
                } else {
                    Checkerboard()
                }
                SlideCanvas(text: text, label: label, theme: theme, mode: mode)
                    .scaleEffect(geo.size.width / designSize.width, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .clipped()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .background(Color.black)
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(_ path: String) -> NSImage? {
        if let i = cache.object(forKey: path as NSString) { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}
