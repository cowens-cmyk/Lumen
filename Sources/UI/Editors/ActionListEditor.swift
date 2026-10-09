import SwiftUI

/// Edits a list of actions — used by macros, slide actions, schedules and MIDI mappings.
struct ActionListEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var actions: [SlideAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PanelHeader(title: "Actions (run in order)")
                Menu("Add Action") { addMenu }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            List {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                    ActionRow(action: Binding(get: { actions[safe: i] ?? a }, set: { if actions.indices.contains(i) { actions[i] = $0 } }))
                }
                .onMove { actions.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { actions.remove(atOffsets: $0) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder private var addMenu: some View {
        let d = app.store.data
        Menu("Set Look") { ForEach(d.looks) { l in Button(l.name) { actions.append(.setLook(l.id)) } } }
        Menu("Show Prop") { ForEach(d.props) { p in Button(p.name) { actions.append(.showProp(p.id)) } } }
        Menu("Hide Prop") { ForEach(d.props) { p in Button(p.name) { actions.append(.hideProp(p.id)) } } }
        Menu("Timer") {
            ForEach(d.timers) { t in
                Menu(t.name) {
                    Button("Start") { actions.append(.startTimer(t.id)) }
                    Button("Stop") { actions.append(.stopTimer(t.id)) }
                    Button("Reset") { actions.append(.resetTimer(t.id)) }
                }
            }
        }
        Button("Send MIDI (Lightkey)") { actions.append(.sendMIDI(MIDIMessage())) }
        Menu("Clear") { ForEach(ClearTarget.allCases, id: \.self) { t in Button(t.title) { actions.append(.clear(t)) } } }
        Menu("Trigger Slide") {
            ForEach(d.presentations.sorted { $0.name < $1.name }) { p in
                Button(p.name) { actions.append(.triggerPresentation(p.id, slide: 0)) }
            }
        }
        Menu("Run Macro") { ForEach(d.macros) { m in Button(m.name) { actions.append(.triggerMacro(m.id)) } } }
        Button("Play Media File…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .image, .audio]
            if panel.runModal() == .OK, let u = panel.url {
                let local = app.store.importMedia(u)
                let kind: MediaKind = u.pathExtension.lowercased().contains("mp3") || u.pathExtension.lowercased() == "wav" || u.pathExtension.lowercased() == "m4a" ? .audio
                    : ["png", "jpg", "jpeg", "heic", "gif", "tiff"].contains(u.pathExtension.lowercased()) ? .image : .video
                actions.append(.playMedia(MediaRef(kind: kind, location: local.path)))
            }
        }
        Button("Open Web Page") { actions.append(.openWeb("https://")) }
        Button("Audience Message") { actions.append(.showMessage("")) }
        Button("Stage Message") { actions.append(.stageMessage("")) }
        Button("Next Slide") { actions.append(.nextSlide) }
        Button("Previous Slide") { actions.append(.previousSlide) }
        Button("Start Slideshow") { actions.append(.startSlideshow(interval: 8)) }
        Button("Stop Slideshow") { actions.append(.stopSlideshow) }
        Button("Wait") { actions.append(.delay(1)) }
    }
}

struct ActionRow: View {
    @Environment(AppModel.self) private var app
    @Binding var action: SlideAction

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            content
        }
    }

    private func name<T: Identifiable>(_ list: [T], _ id: T.ID, _ get: (T) -> String) -> String {
        list.first { $0.id == id }.map(get) ?? "Missing"
    }

    @ViewBuilder private var content: some View {
        let d = app.store.data
        switch action {
        case .setLook(let id): Text("Set Look: \(name(d.looks, id) { $0.name })")
        case .showProp(let id): Text("Show Prop: \(name(d.props, id) { $0.name })")
        case .hideProp(let id): Text("Hide Prop: \(name(d.props, id) { $0.name })")
        case .startTimer(let id): Text("Start Timer: \(name(d.timers, id) { $0.name })")
        case .stopTimer(let id): Text("Stop Timer: \(name(d.timers, id) { $0.name })")
        case .resetTimer(let id): Text("Reset Timer: \(name(d.timers, id) { $0.name })")
        case .triggerMacro(let id): Text("Run Macro: \(name(d.macros, id) { $0.name })")
        case .triggerPresentation(let id, let slide):
            Text("Trigger: \(name(d.presentations, id) { $0.name })")
            Stepper("slide \(slide + 1)", value: Binding(get: { slide }, set: { action = .triggerPresentation(id, slide: max(0, $0)) }))
                .fixedSize()
        case .sendMIDI(let m):
            Text("MIDI")
            Picker("", selection: Binding(get: { m.kind }, set: { var x = m; x.kind = $0; action = .sendMIDI(x) })) {
                Text("Note On").tag(MIDIMessage.Kind.noteOn)
                Text("Note Off").tag(MIDIMessage.Kind.noteOff)
                Text("CC").tag(MIDIMessage.Kind.controlChange)
                Text("Program").tag(MIDIMessage.Kind.programChange)
            }
            .labelsHidden().fixedSize()
            Stepper("ch \(m.channel)", value: Binding(get: { m.channel }, set: { var x = m; x.channel = $0; action = .sendMIDI(x) }), in: 1...16).fixedSize()
            Stepper("# \(m.number)", value: Binding(get: { m.number }, set: { var x = m; x.number = $0; action = .sendMIDI(x) }), in: 0...127).fixedSize()
            if m.kind != .programChange && m.kind != .noteOff {
                Stepper("v \(m.value)", value: Binding(get: { m.value }, set: { var x = m; x.value = $0; action = .sendMIDI(x) }), in: 0...127).fixedSize()
            }
        case .playMedia(let m):
            Text("Play \(m.displayName)")
            if m.kind == .video {
                MediaEndPicker(media: Binding(get: { m }, set: { action = .playMedia($0) }), allowCustom: false).labelsHidden().fixedSize()
            }
        case .showMessage(let s):
            Text("Message")
            TextField("text", text: Binding(get: { s }, set: { action = .showMessage($0) }))
        case .stageMessage(let s):
            Text("Stage")
            TextField("text", text: Binding(get: { s }, set: { action = .stageMessage($0) }))
        case .openWeb(let u):
            Text("Web")
            TextField("URL", text: Binding(get: { u }, set: { action = .openWeb($0) }))
        case .delay(let s):
            Text("Wait")
            Stepper(String(format: "%.1fs", s), value: Binding(get: { s }, set: { action = .delay(max(0, $0)) }), step: 0.5).fixedSize()
        case .startSlideshow(let i):
            Text("Slideshow every")
            Stepper("\(Int(i))s", value: Binding(get: { i }, set: { action = .startSlideshow(interval: max(1, $0)) })).fixedSize()
        default:
            Text(action.summary)
        }
        Spacer(minLength: 0)
    }
}
