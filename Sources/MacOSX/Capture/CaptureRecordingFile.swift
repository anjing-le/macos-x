import Foundation

/// Keep the working video on the destination volume. Finalization is a rename,
/// not a full video copy; a failed rename retains the completed working file.
enum CaptureRecordingFile {
    static func workingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".macos-x-\(UUID().uuidString).partial.mp4")
    }

    static func publish(_ working: URL, to destination: URL) -> (url: URL, error: Error?) {
        do {
            // Never overwrite an existing recording, even on a name collision.
            try FileManager.default.moveItem(at: working, to: destination)
            return (destination, nil)
        } catch {
            return (working, error)
        }
    }
}
