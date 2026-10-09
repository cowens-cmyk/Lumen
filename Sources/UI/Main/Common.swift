import SwiftUI

/// Live view of a screen's composited output.
struct ScreenPreview: NSViewRepresentable {
    var renderer: ScreenRenderer?

    func makeNSView(context: Context) -> FrameDisplayView {
        let v = FrameDisplayView(frame: .zero)
        renderer?.addPreview(v)
        return v
    }

    func updateNSView(_ v: FrameDisplayView, context: Context) {
        renderer?.addPreview(v)
    }
}

struct GroupChip: View {
    var name: String
    var color: RGBA
    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.color, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }
}

struct PanelHeader: View {
    var title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ColorBinding {
    static func make(_ b: Binding<RGBA>) -> Binding<Color> {
        Binding(get: { b.wrappedValue.color }, set: { b.wrappedValue = RGBA($0) })
    }
}

extension View {
    func card() -> some View {
        padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Binding into an element of a library array by ID (safe if the element disappears).
@MainActor
func binding<T: Identifiable>(_ array: Binding<[T]>, _ id: T.ID, fallback: T) -> Binding<T> {
    Binding(
        get: { array.wrappedValue.first { $0.id == id } ?? fallback },
        set: { new in
            if let i = array.wrappedValue.firstIndex(where: { $0.id == id }) { array.wrappedValue[i] = new }
        })
}
