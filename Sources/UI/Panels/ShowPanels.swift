import SwiftUI

struct PropsPanel: View {
    @Environment(AppModel.self) private var app
    @State private var editing: UUID?

    var body: some View {
        @Bindable var store = app.store
        List {
            ForEach(app.store.data.props) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name).font(.headline)
                        Text([p.title, p.subtitle].filter { !$0.isEmpty }.joined(separator: " — ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = p.id }.buttonStyle(.borderless)
                    Toggle("", isOn: Binding(get: { app.engine.activeProps[p.id] != nil }, set: { $0 ? app.engine.showProp(p.id) : app.engine.hideProp(p.id) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            .onDelete { store.data.props.remove(atOffsets: $0) }
            Button("Add Lower Third") {
                let p = Prop(name: "New Lower Third", title: "Name", subtitle: "Title")
                store.data.props.append(p)
                editing = p.id
            }
        }
        .sheet(item: Binding(get: { editing.map(IDBox.init) }, set: { editing = $0?.id })) { box in
            PropEditor(prop: binding($store.data.props, box.id, fallback: Prop(name: ""))).environment(app)
        }
    }
}

struct PropEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var prop: Prop

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                TextField("Name", text: $prop.name)
                Picker("Kind", selection: $prop.kind) {
                    Text("Lower Third").tag(PropKind.lowerThird)
                    Text("Text").tag(PropKind.text)
                    Text("Image").tag(PropKind.image)
                }
                TextField("Title", text: $prop.title)
                TextField("Subtitle", text: $prop.subtitle)
                ColorPicker("Bar", selection: ColorBinding.make($prop.style.barColor))
                ColorPicker("Accent", selection: ColorBinding.make($prop.style.accentColor))
                ColorPicker("Text", selection: ColorBinding.make($prop.style.textColor))
                Slider(value: $prop.style.fontSize, in: 20...90) { Text("Size \(Int(prop.style.fontSize))") }
                Stepper("Auto-hide after \(Int(prop.autoHideSeconds))s (0 = stay)", value: $prop.autoHideSeconds, in: 0...120, step: 1)
                if prop.kind == .image {
                    Button("Choose Image…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let u = panel.url { prop.media = MediaRef(kind: .image, location: u.path) }
                    }
                }
            }
            .formStyle(.grouped)
            ZStack {
                Checkerboard()
                OverlayCanvas(props: [prop], message: nil, showProps: true, showMessage: false)
                    .scaleEffect(480 / designSize.width, anchor: .topLeading)
                    .frame(width: 480, height: 270, alignment: .topLeading)
            }
            .frame(width: 480, height: 270).clipped()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 520)
    }
}

struct TimersPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.store
        List {
            ForEach($store.data.timers) { $t in
                let rt = app.engine.timers[t.id] ?? TimerRuntime()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $t.name).textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Text(app.engine.timerValue(t.id))
                            .font(.system(.title2, design: .monospaced).bold())
                            .foregroundStyle(app.engine.timerValue(t.id).hasPrefix("-") ? .red : .primary)
                    }
                    HStack {
                        TimerKindEditor(kind: $t.kind)
                        Spacer()
                        Button(rt.running ? "Stop" : "Start") { rt.running ? app.engine.stopTimer(t.id) : app.engine.startTimer(t.id) }
                        Button("Reset") { app.engine.resetTimer(t.id) }
                    }
                    .controlSize(.small)
                    Text("Use {timer:\(t.name)} in any slide").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .onDelete { store.data.timers.remove(atOffsets: $0) }
            Button("Add Timer") {
                store.data.timers.append(ServiceTimer(name: "Timer \(store.data.timers.count + 1)", kind: .countdown(seconds: 300)))
                app.engine.syncTimersWithLibrary()
            }
        }
    }
}

struct TimerKindEditor: View {
    @Binding var kind: TimerKind

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { tag }, set: { setTag($0) })) {
                Text("Countdown").tag(0)
                Text("Count to time").tag(1)
                Text("Elapsed").tag(2)
            }
            .labelsHidden().fixedSize()
            switch kind {
            case .countdown(let s):
                Stepper("\(Int(s) / 60) min", value: Binding(get: { s / 60 }, set: { kind = .countdown(seconds: $0 * 60) }), in: 1...240)
                    .fixedSize()
            case .countdownTo(let h, let m):
                DatePicker("", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); kind = .countdownTo(hour: c.hour ?? 0, minute: c.minute ?? 0) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
            case .elapsed:
                EmptyView()
            }
        }
    }

    private var tag: Int {
        switch kind { case .countdown: 0; case .countdownTo: 1; case .elapsed: 2 }
    }

    private func setTag(_ t: Int) {
        switch t {
        case 0: kind = .countdown(seconds: 300)
        case 1: kind = .countdownTo(hour: 10, minute: 30)
        default: kind = .elapsed
        }
    }
}

struct MessagesPanel: View {
    @Environment(AppModel.self) private var app
    @AppStorage("savedMessages") private var savedRaw = "Parent of child #___ please come to the nursery\nPlease silence your phones"
    @State private var text = ""
    @State private var stage = ""

    var body: some View {
        Form {
            Section("Audience message") {
                TextField("Message", text: $text)
                HStack {
                    Button("Show") { app.engine.showMessage(text) }.buttonStyle(.borderedProminent)
                    Button("Hide") { app.engine.showMessage(nil) }
                    Spacer()
                    Button("Save") { savedRaw += "\n" + text }.disabled(text.isEmpty)
                }
                ForEach(savedRaw.components(separatedBy: "\n").filter { !$0.isEmpty }, id: \.self) { m in
                    Button(m) { text = m }.buttonStyle(.link)
                }
            }
            Section("Stage message (only the stage display sees this)") {
                TextField("e.g. Wrap up — 2 minutes", text: $stage)
                HStack {
                    Button("Send to Stage") { app.engine.setStageMessage(stage) }.buttonStyle(.borderedProminent)
                    Button("Clear") { app.engine.setStageMessage(nil) }
                }
                ForEach(["Wrap it up", "Speed up", "Slow down", "Repeat chorus", "Go to bridge"], id: \.self) { s in
                    Button(s) { app.engine.setStageMessage(s) }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SchedulePanel: View {
    @Environment(AppModel.self) private var app
    @State private var editing: UUID?

    var body: some View {
        @Bindable var store = app.store
        List {
            Section("Upcoming") {
                if app.scheduler.upcoming.isEmpty { Text("Nothing scheduled").foregroundStyle(.secondary) }
                ForEach(Array(app.scheduler.upcoming.enumerated()), id: \.offset) { _, u in
                    HStack {
                        Text(u.name)
                        Spacer()
                        Text(u.date.formatted(.dateTime.weekday().hour().minute())).foregroundStyle(.secondary)
                    }
                }
                if !app.scheduler.lastFired.isEmpty {
                    Text("Last fired: \(app.scheduler.lastFired)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Triggers") {
                ForEach(store.data.schedules) { s in
                    HStack {
                        Toggle("", isOn: binding($store.data.schedules, s.id, fallback: s).enabled).labelsHidden()
                        Text(s.name)
                        Spacer()
                        Button("Edit") { editing = s.id }.buttonStyle(.borderless)
                    }
                }
                .onDelete { store.data.schedules.remove(atOffsets: $0) }
                Button("Add Scheduled Trigger") {
                    let s = ScheduledTrigger(name: "Walk-in loop", when: .weekly(weekday: 1, hour: 10, minute: 15))
                    store.data.schedules.append(s)
                    editing = s.id
                }
            }
            Section("Calendar") {
                Text("Events in your calendar can fire actions too: put lines like “lumen: macro Walk In” or “lumen: slide Announcements 1” in the event notes. Turn it on in Setup → Calendar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { app.scheduler.refreshUpcoming() }
        .sheet(item: Binding(get: { editing.map(IDBox.init) }, set: { editing = $0?.id })) { box in
            ScheduleEditor(trigger: binding($store.data.schedules, box.id, fallback: ScheduledTrigger(name: "", when: .once(Date()))))
                .environment(app)
        }
    }
}

struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Binding var trigger: ScheduledTrigger

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                TextField("Name", text: $trigger.name)
                Picker("Repeats", selection: Binding(
                    get: { if case .weekly = trigger.when { 1 } else { 0 } },
                    set: { trigger.when = $0 == 1 ? .weekly(weekday: 1, hour: 10, minute: 0) : .once(Date().addingTimeInterval(3600)) })) {
                    Text("Once").tag(0)
                    Text("Weekly").tag(1)
                }
                switch trigger.when {
                case .once(let d):
                    DatePicker("At", selection: Binding(get: { d }, set: { trigger.when = .once($0) }))
                case .weekly(let wd, let h, let m):
                    Picker("Day", selection: Binding(get: { wd }, set: { trigger.when = .weekly(weekday: $0, hour: h, minute: m) })) {
                        ForEach(1...7, id: \.self) { i in Text(Calendar.current.weekdaySymbols[i - 1]).tag(i) }
                    }
                    DatePicker("Time", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            trigger.when = .weekly(weekday: wd, hour: c.hour ?? 0, minute: c.minute ?? 0) }),
                               displayedComponents: .hourAndMinute)
                }
            }
            .formStyle(.grouped)
            ActionListEditor(actions: $trigger.actions).frame(minHeight: 220)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 560, height: 560)
    }
}
