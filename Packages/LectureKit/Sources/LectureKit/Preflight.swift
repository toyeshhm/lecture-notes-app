import AVFoundation
import Foundation

/// Everything that has to be true before a lecture can be recorded, checked
/// while there is still time to fix it.
///
/// The Python CLI had this as `doctor`, and it earned its place: the failures
/// here are all silent-until-it-matters. `claude` not being logged in costs you
/// nothing until the moment the lecture ends and the notes never appear; the ASR
/// models are a multi-gigabyte download that cannot happen in the ninety seconds
/// before class starts. Both are cheap to discover in advance and expensive to
/// discover at the end.
public struct Preflight: Sendable {

    public enum State: String, Sendable, Equatable {
        /// Ready.
        case ok
        /// Works, but something is degraded or unconfirmed.
        case warn
        /// Recording will not produce a note.
        case fail
    }

    public struct Check: Sendable, Equatable, Identifiable {
        public let id: String
        /// What is being checked, in the user's terms rather than the system's.
        public let title: String
        public let state: State
        /// What was found. On a failure this is the whole remedy, so it names the
        /// command or the pane to open rather than describing the problem again.
        public let detail: String

        public init(id: String, title: String, state: State, detail: String) {
            self.id = id
            self.title = title
            self.state = state
            self.detail = detail
        }
    }

    /// Every check, in the order they block on each other: nothing downstream of
    /// a failed platform check is meaningful.
    ///
    /// Runs them concurrently regardless, because the two slow ones (spawning
    /// `claude`, stat-ing a possibly-unmounted vault) are slow for unrelated
    /// reasons and serialising them adds their latencies together on the one
    /// screen a new user is waiting on.
    public static func run(settings: Settings) async -> [Check] {
        async let claude = claudeCheck(settings: settings)
        async let vault = vaultCheck(settings: settings)
        return await [platform(), microphone(), claude, models(), vault]
    }

    // MARK: Checks

    /// FluidAudio runs the ASR models through CoreML on the Neural Engine, so
    /// this is a hard requirement rather than a performance note.
    public static func platform() -> Check {
        #if arch(arm64)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return Check(
            id: "platform", title: "This Mac", state: .ok,
            detail: "Apple silicon, \(version)")
        #else
        return Check(
            id: "platform", title: "This Mac", state: .fail,
            detail: "Transcription runs on the Neural Engine and needs an Apple silicon Mac.")
        #endif
    }

    /// Asked, not requested. Prompting from a preflight screen would spend the
    /// one prompt macOS gives an app before the user has any idea what it is for;
    /// the real request happens when they press record.
    static func microphone() -> Check {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return Check(
                id: "microphone", title: "Microphone", state: .ok, detail: "Access granted")
        case .notDetermined:
            return Check(
                id: "microphone", title: "Microphone", state: .warn,
                detail: "macOS will ask the first time you record.")
        default:
            return Check(
                id: "microphone", title: "Microphone", state: .fail,
                detail: "Denied. Grant it in System Settings › Privacy & Security › Microphone.")
        }
    }

    /// Located *and* logged in. Finding the binary proves nothing: a `claude`
    /// that is present but signed out fails at the last step of a lecture, which
    /// is the most expensive moment for it to fail.
    public static func claudeCheck(settings: Settings) async -> Check {
        guard let path = settings.claudePath ?? ClaudeRunner.locate() else {
            return Check(
                id: "claude", title: "Claude CLI", state: .fail,
                detail: "Not found. Install it, or set its path in Settings.")
        }
        do {
            // A trivial prompt through the real flag stack: the only way to learn
            // whether the subscription actually answers is to ask it something.
            _ = try await ClaudeRunner(claudePath: path).run(
                prompt: "Reply with the single word: ready",
                system: "Reply with exactly one word.",
                model: "haiku",
                timeout: 30)
            return Check(
                id: "claude", title: "Claude CLI", state: .ok,
                detail: path.path(percentEncoded: false))
        } catch LectureKitError.claudeNotLoggedIn {
            return Check(
                id: "claude", title: "Claude CLI", state: .fail,
                detail: "Signed out. Run claude in a terminal, then /login.")
        } catch {
            return Check(
                id: "claude", title: "Claude CLI", state: .warn,
                detail: "Found at \(path.path(percentEncoded: false)), but the test call failed.")
        }
    }

    /// A warning rather than a failure: the models download on first record. It
    /// is here because doing that download over lecture-hall wifi with the
    /// lecturer already talking is the failure this screen exists to prevent.
    static func models() -> Check {
        Transcriber.modelsAreCached
            ? Check(id: "models", title: "Transcription models", state: .ok, detail: "Downloaded")
            : Check(
                id: "models", title: "Transcription models", state: .warn,
                detail: "Not downloaded yet. Fetch them now — it is a large download"
                    + " and it will otherwise happen when you first press record.")
    }

    /// Writable, not merely present. A vault inside a cloud folder that has not
    /// finished mounting reads as existing and rejects the write.
    public static func vaultCheck(settings: Settings) -> Check {
        let courses = settings.coursesDirectory
        guard FileManager.default.fileExists(atPath: settings.vault.path(percentEncoded: false))
        else {
            return Check(
                id: "vault", title: "Vault", state: .fail,
                detail: "Not there: \(settings.vault.path(percentEncoded: false))")
        }

        do {
            try FileManager.default.createDirectory(at: courses, withIntermediateDirectories: true)
            // Actually write. A directory can exist, be listable, and still
            // reject a file — a read-only mount, a sync client holding a lock, a
            // folder owned by another user.
            let probe = courses.appending(path: ".lecture-notes-write-test")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            return Check(
                id: "vault", title: "Vault", state: .fail,
                detail: "Cannot write to \(courses.path(percentEncoded: false)): "
                    + error.localizedDescription)
        }

        let mirrors = settings.mirrors.count
        return Check(
            id: "vault", title: "Vault", state: .ok,
            detail: mirrors == 0
                ? courses.path(percentEncoded: false)
                : "\(courses.path(percentEncoded: false)) · \(mirrors) mirror\(mirrors == 1 ? "" : "s")")
    }
}

extension Array where Element == Preflight.Check {
    /// The worst state present, which is what a summary line has to report:
    /// "4 of 5 ready" beside a green mark is how a blocking failure gets missed.
    public var worst: Preflight.State {
        if contains(where: { $0.state == .fail }) { return .fail }
        return contains(where: { $0.state == .warn }) ? .warn : .ok
    }
}
