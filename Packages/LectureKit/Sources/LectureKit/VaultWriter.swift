import Foundation

/// Writes the note to the primary vault and to every mirror, from one source.
///
/// Each copy is rendered afresh from the note's state rather than copied from
/// another copy, so a mirror can legitimately differ (no transcript, extra
/// frontmatter) without any of them being "the" file that others sync from.
public struct VaultWriter: Sendable {
    private let renderer = NoteRenderer()

    /// Reports a copy that could not be written, by its vault. `saveAll` cannot
    /// throw — the primary note must survive a broken mirror — so this is the
    /// only channel a caller has to learn a copy is missing.
    ///
    /// It fires for a failed *primary* too, with `settings.vault`. Callers that
    /// need to tell the two apart must compare against `settings.vault`, or check
    /// whether `saveAll`'s return value is empty; the name undersells it.
    public var onMirrorFailure: (@Sendable (URL, any Error) -> Void)?

    public init(onMirrorFailure: (@Sendable (URL, any Error) -> Void)? = nil) {
        self.onMirrorFailure = onMirrorFailure
    }

    /// Write the primary copy only.
    @discardableResult
    public func save(_ note: inout LectureNote, settings: Settings) throws -> URL {
        try write(
            &note,
            targetID: settings.targetID,
            vault: settings.vault,
            destination: settings.noteURL(
                course: note.course, date: note.date, topic: note.topic
            ),
            keepTranscript: settings.keepTranscript,
            extraFrontmatter: [:]
        )
    }

    /// Write the primary copy and every mirror, primary first.
    ///
    /// A failing mirror must never cost you the primary note, so each copy is
    /// attempted independently and failures are reported rather than raised.
    @discardableResult
    public func saveAll(_ note: inout LectureNote, settings: Settings) -> [URL] {
        var written: [URL] = []
        // Two targets can resolve to the same file on disk. Writing it a second
        // time would rewrite the primary with the mirror's keepTranscript=false
        // and drop the transcript, which lives only in memory. First write wins,
        // and the primary goes first.
        //
        // Keyed on the resolved destination, not on VaultTargetID: the ID is
        // built from the *raw* subdirs while the path is built from the
        // *sanitised* ones, so "Courses/", "Courses " and "" are three distinct
        // IDs that all land on <vault>/Courses. Comparing IDs misses every one
        // of them; comparing paths cannot.
        // ponytail: lexical comparison. Two vaults symlinked to one directory
        // still collide — resolve symlinks here if that ever shows up.
        var done: Set<URL> = []

        do {
            let url = try save(&note, settings: settings)
            written.append(url)
            done.insert(url.standardizedFileURL)
        } catch {
            onMirrorFailure?(settings.vault, error)
        }

        for mirror in settings.mirrors {
            let destination = mirror.noteURL(
                course: note.course, date: note.date, topic: note.topic
            )
            // A duplicate still gets its relocation bookkeeping: skipping it
            // outright would leave a copy it wrote at some earlier path
            // untracked, and orphaned there for good.
            let duplicate = done.contains(destination.standardizedFileURL)
            do {
                let url = try write(
                    &note,
                    targetID: mirror.targetID,
                    vault: mirror.vault,
                    destination: destination,
                    keepTranscript: mirror.keepTranscript,
                    extraFrontmatter: mirror.frontmatter,
                    renderFile: !duplicate
                )
                if !duplicate {
                    written.append(url)
                    done.insert(url.standardizedFileURL)
                }
            } catch {
                onMirrorFailure?(mirror.vault, error)
            }
        }
        return written
    }

    /// Write one copy, relocating this target's previous copy if it moved.
    ///
    /// Course detection lands mid-recording, so a note that started life in
    /// `_Unsorted` has to migrate without leaving a duplicate behind. Each target
    /// tracks its own previous path, so mirrors relocate independently.
    ///
    /// `renderFile: false` runs the relocation half only, for a target whose
    /// destination another target already wrote this pass. The file is on disk
    /// either way, so this target's stale copy still has to be cleaned up and its
    /// tracked path still has to move — it simply must not overwrite the content.
    private func write(
        _ note: inout LectureNote,
        targetID: VaultTargetID,
        vault: URL,
        destination: URL,
        keepTranscript: Bool,
        extraFrontmatter: [String: String],
        renderFile: Bool = true
    ) throws -> URL {
        let fm = FileManager.default
        if renderFile {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let markdown = renderer.render(
                note, keepTranscript: keepTranscript, extraFrontmatter: extraFrontmatter
            )
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
        }

        let old = note.writtenPaths[targetID]?.standardizedFileURL
        if let old, old != destination.standardizedFileURL, isFile(old),
            !isSameFile(old, destination)
        {
            // Best effort: the new copy is already on disk, and a stale duplicate
            // is a nuisance you can delete. Losing track of the new path is not —
            // the next relocation would orphan it. So never fail out of here.
            try? fm.removeItem(at: old)
            prune(from: old.deletingLastPathComponent(), within: vault)
        }

        note.writtenPaths[targetID] = destination
        return destination
    }

    /// Remove the folders this note vacated, innermost first.
    ///
    /// Two levels, matching the layout we create: `<course>/<lectures>/`. Only
    /// empty directories, and only strictly inside the target's own vault — a
    /// misconfigured vault must not let cleanup walk up into the user's home.
    private func prune(from directory: URL, within vault: URL) {
        // Containment is judged on the *resolved* path. `standardizedFileURL`
        // resolves `.` and `..` but not symlinks, so a course folder symlinked
        // out of the vault reads as inside it while the delete lands wherever
        // the link points. Both sides are resolved, because a vault under a
        // symlinked path (`/tmp`, an external volume) is ordinary.
        let root = PathComponent.normalised(vault).resolvingSymlinksInPath()
        var dir = directory.standardizedFileURL
        for _ in 0..<2 {
            guard isInside(dir.resolvingSymlinksInPath(), root), isEmptyDirectory(dir) else {
                return
            }
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Component-wise, so a sibling vault like `/vaults/notes-old` is not treated
    /// as living inside `/vaults/notes`.
    private func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        return path.count > rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.isEmpty
    }

    /// Whether two paths name the same file on disk.
    ///
    /// macOS volumes are case-insensitive by default, so a course or topic that
    /// changes only in case ("eigenvalues" → "Eigenvalues") produces two paths
    /// that differ as strings and point at one file. Removing the "old" one
    /// there deletes the copy just written, and the note is gone. Compare
    /// identity on disk rather than spelling, which is also right on the
    /// case-sensitive volumes where the two really are separate files.
    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .fileResourceIdentifierKey
        guard
            let lhs = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier,
            let rhs = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return lhs.isEqual(rhs)
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
