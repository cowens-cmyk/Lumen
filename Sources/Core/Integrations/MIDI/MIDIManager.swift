import CoreMIDI
import Foundation
import Observation

/// Virtual MIDI ports so Lightkey (and anything else) can talk to Lumen with no IAC setup.
/// Lumen publishes a "Lumen" source (Lumen → Lightkey) and a "Lumen" destination (Lightkey/controllers → Lumen).
@MainActor
@Observable
final class MIDIManager {
    private(set) var isReady = false
    private(set) var lastSent: String = ""
    private(set) var lastReceived: String = ""
    /// Extra hardware/IAC destinations to also send to (by display name).
    var alsoSendTo: Set<String> = []

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var source = MIDIEndpointRef()
    @ObservationIgnored private var destination = MIDIEndpointRef()
    @ObservationIgnored private var outPort = MIDIPortRef()
    @ObservationIgnored var onMessage: ((MIDIMessage) -> Void)?

    func start(name: String) {
        guard !isReady else { return }
        var status = MIDIClientCreateWithBlock("Lumen" as CFString, &client) { _ in }
        guard status == noErr else { return }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else { return }
        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { [weak self] list, _ in
            let messages = MIDIManager.decode(list)
            Task { @MainActor in
                for m in messages {
                    self?.lastReceived = m.summary
                    self?.onMessage?(m)
                }
            }
        }
        MIDIOutputPortCreate(client, "Lumen Out" as CFString, &outPort)
        isReady = status == noErr
    }

    static func destinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &name)
            return name?.takeRetainedValue() as String?
        }
    }

    func send(_ m: MIDIMessage) {
        guard isReady else { return }
        let ch = UInt8(max(0, min(15, m.channel - 1)))
        let n = UInt8(max(0, min(127, m.number)))
        let v = UInt8(max(0, min(127, m.value)))
        let word: UInt32
        switch m.kind {
        case .noteOn: word = MIDI1UPNoteOn(0, ch, n, v)
        case .noteOff: word = MIDI1UPNoteOff(0, ch, n, v)
        case .controlChange: word = MIDI1UPControlChange(0, ch, n, v)
        case .programChange: word = MIDI1UPChannelVoiceMessage(0, 0xC, ch, n, 0)
        }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDIReceivedEventList(source, &list)
        if !alsoSendTo.isEmpty {
            for i in 0..<MIDIGetNumberOfDestinations() {
                let d = MIDIGetDestination(i)
                var name: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(d, kMIDIPropertyDisplayName, &name)
                if let s = name?.takeRetainedValue() as String?, alsoSendTo.contains(s) {
                    MIDISendEventList(outPort, d, &list)
                }
            }
        }
        lastSent = m.summary
    }

    nonisolated static func decode(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let words = MIDIEventPacket.WordCollection(packet)
            for w in words {
                let type = (w >> 28) & 0xF
                guard type == 0x2 else { continue } // MIDI 1.0 channel voice
                let status = UInt8((w >> 20) & 0xF)
                let channel = Int((w >> 16) & 0xF) + 1
                let d1 = Int((w >> 8) & 0x7F)
                let d2 = Int(w & 0x7F)
                switch status {
                case 0x9 where d2 > 0: out.append(MIDIMessage(kind: .noteOn, channel: channel, number: d1, value: d2))
                case 0x8, 0x9: out.append(MIDIMessage(kind: .noteOff, channel: channel, number: d1, value: 0))
                case 0xB: out.append(MIDIMessage(kind: .controlChange, channel: channel, number: d1, value: d2))
                case 0xC: out.append(MIDIMessage(kind: .programChange, channel: channel, number: d1, value: 0))
                default: break
                }
            }
        }
        return out
    }
}
