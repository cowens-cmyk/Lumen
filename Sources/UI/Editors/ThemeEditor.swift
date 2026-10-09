import SwiftUI

struct ThemeEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var theme: Theme
    @State private var sample = "Amazing grace how sweet the sound\nThat saved a wretch like me"
    @State private var previewMode: RenderMode = .fullSlide

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Form {
                TextField("Name", text: $theme.name)
                Section("Text") {
                    Picker("Font", selection: $theme.fontName) {
                        ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    Slider(value: $theme.fontSize, in: 24...160) { Text("Size \(Int(theme.fontSize))") }
                    Toggle("Bold", isOn: $theme.bold)
                    Toggle("UPPERCASE", isOn: $theme.uppercase)
                    ColorPicker("Color", selection: ColorBinding.make($theme.textColor))
                    Picker("Align", selection: $theme.align) {
                        Text("Left").tag(HAlign.leading); Text("Center").tag(HAlign.center); Text("Right").tag(HAlign.trailing)
                    }
                    Picker("Vertical", selection: $theme.vAlign) {
                        Text("Top").tag(VAlign.top); Text("Middle").tag(VAlign.middle); Text("Bottom").tag(VAlign.bottom)
                    }
                    Slider(value: $theme.padding, in: 20...400) { Text("Margin") }
                    Slider(value: $theme.lineSpacing, in: 0...40) { Text("Line spacing") }
                    Toggle("Shadow", isOn: $theme.shadow)
                    Slider(value: $theme.outlineWidth, in: 0...8) { Text("Outline") }
                    Toggle("Shrink to fit", isOn: $theme.autoFit)
                    Stepper("Lines per slide: \(theme.maxLinesPerSlide)", value: $theme.maxLinesPerSlide, in: 1...12)
                }
                Section("Background") {
                    ColorPicker("Color", selection: ColorBinding.make($theme.background))
                    HStack {
                        Text(theme.backgroundMedia?.displayName ?? "No image/video")
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            if panel.runModal() == .OK, let u = panel.url {
                                theme.backgroundMedia = MediaRef(kind: .image, location: app.store.importMedia(u).path)
                            }
                        }
                        if theme.backgroundMedia != nil { Button("Remove") { theme.backgroundMedia = nil } }
                    }
                }
                Section("Reference label (scripture)") {
                    Toggle("Show label", isOn: $theme.showLabel)
                    Slider(value: $theme.labelSize, in: 16...80) { Text("Label size") }
                    ColorPicker("Label color", selection: ColorBinding.make($theme.labelColor))
                }
                Section("Lower third (used by Looks on the livestream)") {
                    ColorPicker("Bar", selection: ColorBinding.make($theme.lowerThird.barColor))
                    ColorPicker("Accent", selection: ColorBinding.make($theme.lowerThird.accentColor))
                    ColorPicker("Text", selection: ColorBinding.make($theme.lowerThird.textColor))
                    Slider(value: $theme.lowerThird.fontSize, in: 20...90) { Text("Text size \(Int(theme.lowerThird.fontSize))") }
                    Slider(value: $theme.lowerThird.bottomMargin, in: 0...300) { Text("Bottom margin") }
                    Slider(value: $theme.lowerThird.sideMargin, in: 0...400) { Text("Side margin") }
                    Slider(value: $theme.lowerThird.cornerRadius, in: 0...40) { Text("Corners") }
                    Toggle("Show reference", isOn: $theme.lowerThird.showReference)
                    Picker("Align", selection: $theme.lowerThird.align) {
                        Text("Left").tag(HAlign.leading); Text("Center").tag(HAlign.center); Text("Right").tag(HAlign.trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Preview", selection: $previewMode) {
                    ForEach(RenderMode.allCases.filter { $0 != .hidden }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                SlidePreview(text: sample, label: "John 3:16 ESV", theme: theme, mode: previewMode)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                TextField("Sample text", text: $sample, axis: .vertical)
            }
        }
    }
}
