import Foundation

/// What was on the outputs, saved as it changes, so a crash or force-quit mid-service can be undone in one click.
struct SessionSnapshot: Codable, Equatable {
    var cleanExit: Bool
    var presentationID: UUID?
    var presentationName: String?
    var index: Int?
    var playlistID: UUID?
    var lookID: UUID?
    var savedAt: Date

    /// Only offer recovery for a recent, unclean end of a session that had something live.
    func isRecoverable(now: Date = Date(), maxAge: TimeInterval = 8 * 3600) -> Bool {
        !cleanExit && presentationID != nil && index != nil && now.timeIntervalSince(savedAt) < maxAge
    }

    static func load(from folder: URL) -> SessionSnapshot? {
        guard let raw = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder.lumen.decode(SessionSnapshot.self, from: raw)
    }

    func save(to folder: URL) {
        guard let raw = try? JSONEncoder.lumen.encode(self) else { return }
        try? raw.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
    }
}
