import Foundation

/// Recordings dropped into the vault from somewhere else, waiting to be written
/// up.
///
/// The transport is the vault itself. An Obsidian vault already syncs to a phone
/// through Dropbox or iCloud, so a recording shared into a folder inside it
/// arrives on the Mac with no networking, no pairing, no server and no account —
/// which is why this is a folder scan and not a protocol. Record with Voice
/// Memos on the way out of the lecture hall, share it into the inbox, and the
/// Mac writes the notes the next time it is awake.
///
/// The inbox lives **outside** `coursesSubdir` on purpose: `CourseDetector`
/// treats every directory under the courses folder as a course, so an inbox in
/// there would show up in the sidebar as a course called `_Inbox`.
public enum InboxWatcher {

    /// Extensions worth trying. `AVAudioFile` decodes all of these through
    /// CoreAudio, and `.m4a` is what an iPhone actually produces — verified by
    /// transcribing one rather than assumed from the format list.
    static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "aac", "caf", "aiff", "aif", "mp4"]

    /// What kind of thing is waiting. The two are processed differently — one is
    /// transcribed, the other read — and everything after that is shared.
    public enum Kind: String, Sendable, Equatable {
        case audio
        case pdf
    }

    /// A recording that is ready to process, with the facts needed to decide
    /// whether it is worth spending a model call on.
    public struct Pending: Sendable, Equatable, Identifiable {
        public var url: URL
        public var bytes: Int64
        /// When it landed. Used as the note's date, because the file's own
        /// modification time is closer to when the lecture happened than the
        /// moment the Mac woke up and noticed it.
        public var modified: Date
        public var kind: Kind
        public var id: URL { url }
    }

    /// Everything in the inbox that is settled enough to read.
    ///
    /// - Parameter settledFor: how long a file's size must have stopped changing
    ///   before it counts. This is the whole reason the function is not a plain
    ///   directory listing: Dropbox and iCloud write a file progressively, so a
    ///   scan that fires the moment a file appears reads a partial recording and
    ///   transcribes the first thirty seconds of a lecture as though it were all
    ///   of it. The failure is silent — a short note that looks complete.
    public static func pending(
        in directory: URL, settledFor: TimeInterval = 20
    ) -> [Pending] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let now = Date()
        return names.compactMap { url -> Pending? in
            let ext = url.pathExtension.lowercased()
            let kind: Kind
            if audioExtensions.contains(ext) {
                kind = .audio
            } else if ext == "pdf" {
                kind = .pdf
            } else {
                return nil
            }

            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ]), values.isRegularFile == true,
                let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }

            // A file still being written keeps moving its modification date. A
            // sync client that has finished leaves it alone.
            guard now.timeIntervalSince(modified) >= settledFor else { return nil }
            // Anything this small is not material — an interrupted share, a
            // zero-byte placeholder, or a two-second misfire. Processing one
            // spends a model call to produce a note about nothing.
            let floor = kind == .audio ? minimumAudioBytes : minimumPDFBytes
            guard size >= floor else { return nil }

            return Pending(url: url, bytes: Int64(size), modified: modified, kind: kind)
        }
        // Oldest first: lectures are written up in the order they happened.
        .sorted { $0.modified < $1.modified }
    }

    /// Roughly twenty seconds of AAC at a voice bitrate. Below this there is
    /// nothing to summarise.
    static let minimumAudioBytes = 60_000

    /// A PDF gets its own floor, and a far smaller one: a legitimate one-page
    /// handout is a few kilobytes, and applying the audio figure would discard
    /// it silently. This only has to reject a zero-byte sync placeholder.
    static let minimumPDFBytes = 1_000

    /// Where processed audio goes.
    ///
    /// Moved rather than deleted. The recording is the only part of a lecture
    /// that cannot be regenerated, and a bug in the notes pass is not a reason
    /// to have destroyed it — it is the reason to still have it.
    public static func archive(_ url: URL, in directory: URL) throws -> URL {
        let done = directory.appending(path: "Written up", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)

        var destination = done.appending(path: url.lastPathComponent)
        // A second recording sharing a name would otherwise overwrite the first.
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let stem = url.deletingPathExtension().lastPathComponent
            destination = done.appending(path: "\(stem) \(suffix).\(url.pathExtension)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Creates the inbox and drops a note in it explaining what it is for.
    ///
    /// The folder appears inside a vault the user browses in Obsidian, so an
    /// unexplained `_Lecture Inbox` is a folder they will eventually delete.
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appending(path: "README.md")
        guard !FileManager.default.fileExists(atPath: readme.path(percentEncoded: false)) else { return }
        try """
            # Lecture inbox

            Audio dropped in here is transcribed and written up by Lecture Notes,
            then filed under the course it worked out, exactly as if you had
            recorded it in the app. A PDF dropped in here is read and written up
            the same way.

            The point of this folder is your phone. Record a lecture with Voice
            Memos, share it into this folder, and it syncs here. Nothing needs to
            be installed on the phone and nothing needs to be paired.

            Processing happens when the Mac is awake and the app is running. The
            file itself is moved into `Written up/` rather than deleted.
            """.write(to: readme, atomically: true, encoding: .utf8)
    }
}
