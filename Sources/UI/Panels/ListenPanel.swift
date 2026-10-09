import SwiftUI

struct ListenPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var listening = app.listening
        @Bindable var store = app.store
        Form {
            Section {
                HStack {
                    Button {
                        if listening.isListening { listening.stop() } else { Task { await listening.start() } }
                    } label: {
                        Label(listening.isListening ? "Stop Listening" : "Start Listening",
                              systemImage: listening.isListening ? "stop.circle.fill" : "waveform.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(listening.isListening ? .red : .accentColor)
                    Spacer()
                    LevelMeter(level: listening.level).frame(width: 90, height: 8)
                }
                Picker("Audio input", selection: $store.data.settings.listenInputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(ListeningService.inputDevices()) { d in Text(d.name).tag(d.id) }
                }
                .disabled(listening.isListening)
                if let e = listening.lastError { Text(e).foregroundStyle(.red).font(.caption) }
            } footer: {
                Text("Feed it a clean vocal or pastor mic from the sound board (USB/Dante/aux). Recognition runs on this Mac — nothing is uploaded.")
            }

            Section("Lyric following") {
                Toggle("Follow lyrics and advance slides", isOn: $listening.followLyrics)
                Toggle("Advance automatically (off = suggest only)", isOn: $listening.autoAdvance)
                Slider(value: $store.data.settings.lyricFollowThreshold, in: 0.4...0.9) {
                    Text("Sensitivity")
                } minimumValueLabel: { Text("Eager").font(.caption) } maximumValueLabel: { Text("Careful").font(.caption) }
                ConfidenceView(confidence: listening.confidence, status: listening.status, active: listening.followLyrics)
                Button("Take Over (Esc)") { listening.takeOver() }
                    .disabled(!listening.followLyrics)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Section("Scripture detection") {
                Toggle("Detect Bible references the pastor mentions", isOn: $listening.detectScripture)
                Text("Detected passages appear in the Scripture tab, ready to display with one click.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if listening.isListening {
                Section("Hearing") {
                    Text(listening.transcript.isEmpty ? "…" : String(listening.transcript.suffix(220)))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ConfidenceView: View {
    var confidence: Double
    var status: String
    var active: Bool

    var color: Color { confidence > 0.7 ? .green : confidence > 0.45 ? .yellow : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(active ? color : .gray).frame(width: 10, height: 10)
                Text(active ? status : "Not following").font(.callout.weight(.medium))
                Spacer()
                Text(active ? "\(Int(confidence * 100))%" : "—").font(.callout.monospacedDigit())
            }
            ProgressView(value: active ? confidence : 0).tint(color)
        }
    }
}

struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.5 ? Color.red : .green)
                    .frame(width: g.size.width * CGFloat(min(1, level * 4)))
            }
        }
    }
}

struct ListenToolbarIndicator: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let l = app.listening
        if l.isListening && l.followLyrics {
            Button { l.takeOver() } label: {
                HStack(spacing: 5) {
                    Circle().fill(l.confidence > 0.7 ? .green : l.confidence > 0.45 ? .yellow : .red).frame(width: 8, height: 8)
                    Text("AI \(Int(l.confidence * 100))%").font(.caption.monospacedDigit())
                }
            }
            .help("Lyric follow: \(l.status). Click or press Esc to take over.")
        }
    }
}
