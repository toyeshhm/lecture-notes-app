import LectureKit
import SwiftUI

/// The determination sheet: where notes go, who writes them, and what is kept.
///
/// macOS's `Form` is the wrong instrument. It brings its own inset grouped
/// cards, and §5 has no cards anywhere in it, so the rows are built by hand: a
/// label column, a control column held clear of it, and sections divided by the
/// caption-over-hairline head the sidebar uses (§5.1). One sheet mounted on the
/// board, like every other surface here that is read rather than glanced at.
///
/// Text fields commit on Return or on blur, never per keystroke: a half-typed
/// vault path is not a vault path, and saving one sends the next library scan
/// walking a directory that does not exist.
struct SettingsView: View {

    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mirror awaiting its removal confirmation, by position. Removing one
    /// stops a second copy of every future lecture being written, so it is the
    /// destructive act on this sheet and it is confirmed in place.
    @State private var mirrorToRemove: Int?

    /// The CLI import awaiting its confirmation: it replaces every field here.
    @State private var confirmingImport = false

    /// Said only when the import found nothing, which is otherwise indistinguish-
    /// able from an import that worked and changed nothing.
    @State private var importFailure: String?

    /// A vault path outruns any sensible field, so the field scrolls rather than
    /// being sized to its content. This is wide enough to hold a subdirectory or
    /// a model alias whole, which is what is actually read back at a glance.
    private static let fieldWidth = Spacing.mount * 5

    /// Aliases the `claude` binary resolves today. Offered, not enforced: the CLI
    /// takes anything it accepts, and a closed picker is wrong the day a new
    /// model ships.
    private static let knownModels = ["opus", "sonnet", "haiku"]

    /// The course the worked example is filed under when nothing is pinned.
    private static let exampleCourse = "Analysis II"

    @State private var roster: [RosterEntry] = []
    @State private var newCourseCode = ""
    @State private var newCourseName = ""
    @State private var rosterError: String?
    /// The Claude sign-in probe, nil until the first one returns.
    @State private var claudeCheck: Preflight.Check?
    @State private var isCheckingClaude = false

    /// A course as this screen sees it: on the roster, in the vault, or both.
    struct RosterEntry {
        let code: String
        let name: String
        /// False for a course that exists only as a folder. Those cannot be
        /// removed from here, because removing them means deleting lectures.
        let inRoster: Bool
    }

    var body: some View {
        ScrollView {
            sheet
                .frame(maxWidth: Spacing.sheetMax)
                .frame(maxWidth: .infinity)   // centres the sheet, grows the mount
                .padding(.horizontal, Spacing.mount)
                .padding(.vertical, Spacing.plate)
        }
        .background(BoardBackground())
        .task(id: session.settings.coursesDir.path(percentEncoded: false)) { await loadRoster() }
    }

    // MARK: Roster

    private func loadRoster() async {
        let directory = session.settings.coursesDir
        let (written, folders) = await Task.detached {
            (CourseDetector.readRoster(in: directory), CourseDetector.candidates(in: directory))
        }.value

        roster = Set(written.keys).union(folders.keys)
            .map { RosterEntry(code: $0, name: written[$0] ?? folders[$0] ?? "", inRoster: written[$0] != nil) }
            .sorted { first, second in
                let firstIsUnsorted = first.code == unsortedFolder
                let secondIsUnsorted = second.code == unsortedFolder
                if firstIsUnsorted != secondIsUnsorted { return secondIsUnsorted }
                return first.code.localizedStandardCompare(second.code) == .orderedAscending
            }
    }

    private func addCourse() {
        let code = newCourseCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        var written = Dictionary(uniqueKeysWithValues: roster.filter(\.inRoster).map { ($0.code, $0.name) })
        written[code] = newCourseName.trimmingCharacters(in: .whitespaces)
        commitRoster(written)
        newCourseCode = ""
        newCourseName = ""
    }

    private func removeCourse(_ code: String) {
        var written = Dictionary(uniqueKeysWithValues: roster.filter(\.inRoster).map { ($0.code, $0.name) })
        written.removeValue(forKey: code)
        commitRoster(written)
    }

    /// Writes and re-reads. Re-reading rather than mutating the local array is
    /// what makes the screen show what is actually in the file — including a
    /// course that stayed listed because it still has a folder.
    private func commitRoster(_ written: [String: String]) {
        do {
            try RosterWriter.write(written, in: session.settings.coursesDir)
            rosterError = nil
            Task { await loadRoster() }
        } catch {
            rosterError = "Couldn't write the roster: \(error.localizedDescription)"
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            destination
            courseSection
            mirrorSection
            modelSection
            recordingSection
            binarySection
            importSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The fill sits outside the frame, per `PlateFrame`'s contract: mounted
        // inside it, the border band would be board — grain and all — inside the
        // rule that is meant to close the sheet.
        .plateFrame(padding: Spacing.sheetPadding)
        .background(Palette.sheet)
        // The only motion on this sheet is a confirmation opening under the
        // control that armed it — `settle`, the same step a row fill uses, and
        // instant under Reduce Motion (§6).
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: mirrorToRemove)
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: confirmingImport)
    }

    // MARK: - Where notes go

    private var destination: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("Where notes go")

            Row(label: "Vault") {
                pathControl(url: session.settings.vault, choose: "Choose a vault", named: "Vault") {
                    guard let picked = pick(directories: true, startingAt: session.settings.vault)
                    else { return }
                    // Assigning the property skips `Settings.init`'s normalising,
                    // and relocation tracking is keyed off the normalised path:
                    // `/a/b` and `/a/b/` would otherwise be two vaults holding one
                    // file, and a mirror could overwrite the primary believing it
                    // was a separate target.
                    update { $0.vault = PathComponent.normalised(picked) }
                }
            }

            textRow(
                "Courses folder", value: session.settings.coursesSubdir, prompt: "Courses",
                hint: "Inside the vault. May be nested, like 02 Areas/Courses."
            ) { text in update { $0.coursesSubdir = text } }

            textRow(
                "Lectures folder", value: session.settings.lecturesSubdir, prompt: "Lectures",
                hint: "Inside each course's own folder."
            ) { text in update { $0.lecturesSubdir = text } }

            workedExample
        }
    }

    /// Where a lecture actually lands, resolved live through the builder the
    /// writer itself uses — sanitising included, so a subdirectory that will be
    /// rewritten on disk is shown rewritten rather than as typed. The two
    /// subdirectory fields are the most confusing thing on this sheet and a
    /// worked example is worth more than any amount of label.
    private var workedExample: some View {
        let course = session.settings.pinnedCourse ?? Self.exampleCourse
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            SpecimenLabel(title: "A lecture filed under \(course) lands in")
            Text(session.settings.lectureDirectory(course: course).path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)   // the whole point of showing it
        }
        .padding(.top, Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Courses

    /// The roster, editable here rather than only in Obsidian.
    ///
    /// Detection reads this list, so keeping it current is what makes a lecture
    /// land in the right folder — and until now the only way to edit it was to
    /// open `courses.md` in another app. Folders in the vault are courses too and
    /// are shown greyed with no delete: this list writes one file, and a folder
    /// full of lectures is not something a settings screen should offer to
    /// remove.
    private var courseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("Courses")

            Text("Detection picks from this list. A course with a folder in the vault is listed whether or not it is written here.")
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(roster, id: \.code) { entry in
                courseRow(entry)
            }

            HStack(spacing: Spacing.md) {
                FieldText(
                    value: newCourseCode, name: "New course code",
                    prompt: "CS 314H", width: 160,
                    commit: { text in newCourseCode = text; return text })
                FieldText(
                    value: newCourseName, name: "New course name",
                    prompt: "Data Structures", width: 240,
                    commit: { text in newCourseName = text; return text })
                action("Add") { addCourse() }
                    .disabled(newCourseCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let rosterError {
                Text(rosterError)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func courseRow(_ entry: RosterEntry) -> some View {
        HStack(spacing: Spacing.md) {
            Text(entry.code == unsortedFolder ? "Unsorted" : entry.code)
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)
                .frame(width: 160, alignment: .leading)
            Text(entry.name.isEmpty ? "—" : entry.name)
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.inRoster {
                action("Remove") { removeCourse(entry.code) }
            } else {
                // A folder, not a roster line. Saying so is the point: otherwise
                // the absence of a Remove button reads as a bug.
                Text("folder")
                    .font(Typography.micro)
                    .tracking(Typography.microTracking)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Mirrors

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("Mirrors")

            if session.settings.mirrors.isEmpty {
                prose("A mirror writes a second copy of every lecture into another vault, from the same source in one pass. Nothing is ever synced from a copy.", tone: Palette.inkSoft)
            }

            // ponytail: keyed by position. `MirrorTarget` is not `Identifiable`
            // and nothing on it is unique — two mirrors may share a vault and
            // differ only in subdirectory.
            ForEach(Array(session.settings.mirrors.enumerated()), id: \.offset) { index, mirror in
                mirrorBlock(index: index, mirror: mirror)
            }

            action("Add a mirror") {
                // Seeded with the primary vault, not the home directory: an
                // unconfigured mirror pointing at $HOME scatters lecture notes
                // across it the moment the next lecture ends.
                update { $0.mirrors.append(MirrorTarget(vault: $0.vault)) }
            }
        }
    }

    /// The mirror's own worked example, and the one thing it has to say that the
    /// primary's does not.
    ///
    /// A freshly added mirror resolves to *exactly* the primary's directory,
    /// because it is seeded with the primary vault and takes the default
    /// subdirectories. `VaultWriter` detects the duplicate and correctly writes
    /// one file — so the row sat there fully populated, looking like a working
    /// second copy, writing nothing, forever, until someone changed the vault.
    /// The dedup is right; the silence about it was not.
    ///
    /// The mirror is also the target most likely to be pointed somewhere unusual
    /// and was the one with no feedback at all: `PathComponent.relativePath`
    /// rewrites what is typed, and nothing showed the rewrite.
    @ViewBuilder
    private func mirrorDestination(index: Int, mirror: MirrorTarget) -> some View {
        let course = session.settings.pinnedCourse ?? Self.exampleCourse
        let destination = mirror.noteURL(course: course, date: "2026-01-01", topic: "x")
            .deletingLastPathComponent()
        let isPrimary = destination.standardizedFileURL
            == session.settings.lectureDirectory(course: course).standardizedFileURL

        VStack(alignment: .leading, spacing: Spacing.xs) {
            SpecimenLabel(title: "The copy lands in")
            Text(destination.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if isPrimary {
                Text("Same folder as the primary, so no second copy is written."
                    + " Give this mirror a different vault or a different courses folder.")
                    .font(Typography.ui)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func mirrorBlock(index: Int, mirror: MirrorTarget) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SpecimenLabel(title: "Mirror \(index + 1)")

            Row(label: "Vault") {
                pathControl(
                    url: mirror.vault, choose: "Choose a vault",
                    named: "Mirror \(index + 1) vault"
                ) {
                    guard let picked = pick(directories: true, startingAt: mirror.vault) else { return }
                    updateMirror(index) { $0.vault = PathComponent.normalised(picked) }
                }
            }

            textRow(
                "Courses folder", value: mirror.coursesSubdir, prompt: "Courses",
                hint: "Inside this vault. May be nested, like 02 Areas/Courses.",
                named: "Mirror \(index + 1) courses folder"
            ) { text in
                updateMirror(index) { $0.coursesSubdir = text }
            }

            textRow(
                "Lectures folder", value: mirror.lecturesSubdir, prompt: "Lectures",
                hint: "Inside each course folder.",
                named: "Mirror \(index + 1) lectures folder"
            ) { text in
                updateMirror(index) { $0.lecturesSubdir = text }
            }

            markRow(
                "Transcript", isOn: mirror.keepTranscript,
                named: "Keep the transcript in mirror \(index + 1)",
                hint: "Kept at the bottom of this copy of the note."
            ) { on in updateMirror(index) { $0.keepTranscript = on } }

            mirrorDestination(index: index, mirror: mirror)

            Row(
                label: "Frontmatter",
                hint: "Merged into this copy's YAML header. Marking it agent-generated, say."
            ) {
                frontmatter(index: index, pairs: mirror.frontmatter)
            }

            removeMirror(index: index)
        }
        .padding(.vertical, Spacing.sm)
    }

    private func frontmatter(index: Int, pairs: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(pairs.keys.sorted(), id: \.self) { key in
                HStack(spacing: Spacing.sm) {
                    field(key, named: "Frontmatter key", prompt: "key", width: Spacing.mount * 2) {
                        rename(index: index, from: key, to: $0)
                    }
                    field(pairs[key] ?? "", named: "Value for \(key)", prompt: "value", width: Spacing.mount * 2) { text in
                        updateMirror(index) { $0.frontmatter[key] = text }
                        return text
                    }
                    Button {
                        updateMirror(index) { $0.frontmatter[key] = nil }
                    } label: {
                        Text("✕").font(Typography.ui).foregroundStyle(Palette.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove the frontmatter key \(key)")
                }
            }
            action("Add a pair") { updateMirror(index) { $0.frontmatter[Self.freshKey(in: pairs)] = "" } }
        }
    }

    /// A rename is a remove and an insert, and both halves can fail: an empty key
    /// is not a key, and reusing an existing one silently drops the pair it
    /// collided with. Either way the old key stands, and returning it snaps the
    /// field back rather than leaving it showing an edit that did not happen.
    private func rename(index: Int, from key: String, to typed: String) -> String {
        let new = typed.trimmingCharacters(in: .whitespaces)
        guard new != key, !new.isEmpty else { return key }
        guard session.settings.mirrors.indices.contains(index),
              session.settings.mirrors[index].frontmatter[new] == nil else { return key }
        updateMirror(index) {
            $0.frontmatter[new] = $0.frontmatter[key]
            $0.frontmatter[key] = nil
        }
        return new
    }

    private static func freshKey(in pairs: [String: String]) -> String {
        var key = "key"
        var suffix = 2
        while pairs[key] != nil {
            key = "key \(suffix)"
            suffix += 1
        }
        return key
    }

    /// The destructive act on this sheet, in the form §5.3 sets for Discard: the
    /// copy sets in `ink` and only the stamp glyph carries the pigment.
    @ViewBuilder private func removeMirror(index: Int) -> some View {
        if mirrorToRemove == index {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("✕").font(Typography.ui).foregroundStyle(Palette.stamp)
                prose("Every future lecture stops being copied to this vault. Notes already written stay where they are.", tone: Palette.ink)
            }
            HStack(spacing: Spacing.lg) {
                action("Remove it") {
                    mirrorToRemove = nil
                    update {
                        guard $0.mirrors.indices.contains(index) else { return }
                        $0.mirrors.remove(at: index)
                    }
                }
                action("Keep it") { mirrorToRemove = nil }
            }
        } else {
            action("Remove this mirror") { mirrorToRemove = index }
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("Models")
            modelRow(
                "Live model", value: session.settings.liveModel,
                hint: "Writes the interim notes during the lecture."
            ) { alias in update { $0.liveModel = alias } }
            modelRow(
                "Final model", value: session.settings.finalModel,
                hint: "Writes the whole lecture once, when you stop."
            ) { alias in update { $0.finalModel = alias } }
            modelRow(
                "Detect model", value: session.settings.detectModel,
                hint: "Names the course and the topic from what was said."
            ) { alias in update { $0.detectModel = alias } }
        }
    }

    private func modelRow(
        _ label: String, value: String, hint: String, commit: @escaping (String) -> Void
    ) -> some View {
        Row(label: label, hint: hint) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                field(value, named: label, prompt: "sonnet") { text in
                    let alias = text.trimmingCharacters(in: .whitespaces)
                    // An empty model is not a default: it is a `--model` flag with
                    // nothing after it, and a call that fails at the end of a
                    // lecture rather than at the start of one.
                    guard !alias.isEmpty else { return value }
                    commit(alias)
                    return alias
                }
                HStack(spacing: Spacing.sm) {
                    ForEach(Self.knownModels, id: \.self) { alias in
                        Button { commit(alias) } label: {
                            Text(alias)
                                .font(Typography.caption.smallCaps())
                                .tracking(Typography.captionTracking)
                                .foregroundStyle(alias == value ? Palette.ink : Palette.inkSoft)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(alias) as the \(label.lowercased())")
                        .accessibilityAddTraits(alias == value ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    // MARK: - Recording

    /// Six hours, in seconds. Not a real limit on lectures so much as the point
    /// past which a pass interval has stopped meaning anything.
    private static let longestLecture: Double = 6 * 60 * 60

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("Recording")

            // Wall-clock, stamped at the *start* of a pass
            // (`SessionModel.livePassIfDue`), so successive sets of notes are this
            // far apart rather than this-far-plus-however-long-the-model-took.
            //
            // It is a floor, not a schedule: the check only runs when confirmed
            // speech arrives, so silence does not fire a pass — it defers one.
            // Saying "seconds of speech" described a mechanism that does not
            // exist, and the interval is not measured in speech time.
            Row(label: "Live pass", hint: "Seconds between one set of interim notes and the next.") {
                field(String(Int(session.settings.liveInterval)), named: "Live pass", prompt: "180") { text in
                    guard let seconds = Double(text) else {
                        return String(Int(session.settings.liveInterval))
                    }
                    // Both ends, not just the floor. `Double("1e999")` is `inf`
                    // and `Double("99999999999999999999")` is finite but past
                    // `Int.max`; either one traps in `Int(_:)` on the way back to
                    // the field, so twenty nines typed into this box crashed the
                    // app. The ceiling is a lecture: a pass interval longer than
                    // that produces no interim notes at all, which is what the
                    // toggle below is for.
                    //
                    // Each pass is a model call fired from the transcript stream.
                    // At zero that is one call per recognised phrase, which spends
                    // a subscription faster than it produces notes.
                    let clamped = seconds.isFinite ? min(max(5, seconds), Self.longestLecture) : 180
                    update { $0.liveInterval = clamped }
                    return String(Int(clamped))
                }
            }

            Row(label: "Minimum words", hint: "A live pass waits until this many new words have been said. Useful when a lecturer works at the board in silence.") {
                field(String(session.settings.minWordsPerPass), named: "Minimum words", prompt: "40") { text in
                    // `Int(_:)` returns nil on overflow rather than trapping, so
                    // this one is safe from the crash above — but it still needs a
                    // ceiling, because a floor no lecture reaches means no interim
                    // notes and no explanation of why.
                    guard let words = Int(text) else { return String(session.settings.minWordsPerPass) }
                    let clamped = min(max(0, words), 5000)
                    update { $0.minWordsPerPass = clamped }
                    return String(clamped)
                }
            }

            markRow(
                "From your phone", isOn: session.settings.watchesInbox,
                named: "Write up recordings dropped in the vault inbox",
                hint: "Audio shared into _Lecture Inbox in your vault is transcribed and filed like any other lecture. Record with Voice Memos, share it to the folder, and it is written up next time this Mac is awake."
            ) { on in update { $0.watchesInbox = on } }

            markRow(
                "Transcript", isOn: session.settings.keepTranscript, named: "Keep the transcript",
                hint: "The full text is kept at the bottom of the note."
            ) { on in update { $0.keepTranscript = on } }

            markRow(
                "Audio", isOn: session.settings.keepAudio, named: "Keep the audio",
                hint: "The recording is kept as a .wav beside the note, which is what makes playback possible. A term of lectures is several gigabytes sitting in the vault, and syncing wherever the vault syncs."
            ) { on in update { $0.keepAudio = on } }

            textRow(
                "Pinned course", value: session.settings.pinnedCourse ?? "", prompt: "Detect it",
                hint: "Files every lecture here instead of detecting the course. Leave it empty to detect. Detection still supplies the topic either way."
            ) { typed in
                let course = typed.trimmingCharacters(in: .whitespaces)
                update { $0.pinnedCourse = course.isEmpty ? nil : course }
            }
        }
    }

    // MARK: - The claude binary

    private var binarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            head("The claude binary")

            Row(
                label: "Path",
                hint: "The notes are written by the claude CLI on this Mac, under your own subscription. Set this only when it lives somewhere the app does not look."
            ) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    pathControl(
                        url: session.settings.claudePath, placeholder: locatedDefault,
                        choose: "Choose the binary", named: "Claude binary"
                    ) {
                        guard let picked = pick(
                            directories: false,
                            startingAt: session.settings.claudePath ?? ClaudeRunner.locate()
                        ) else { return }
                        update { $0.claudePath = picked }
                    }
                    if session.settings.claudePath != nil {
                        action("Search for it instead") { update { $0.claudePath = nil } }
                    }
                }
            }

            Row(
                label: "Sign-in",
                hint: "Notes are written under your own Claude subscription rather than metered API credit, so the CLI has to be signed in. The app cannot sign in for you — Claude's login runs in a terminal."
            ) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        DeterminationMark(state: claudeCheck?.state)
                        Text(claudeCheck?.detail ?? "Checking…")
                            .font(Typography.ui)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Spacing.measure, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(DeterminationMark.word(for: claudeCheck?.state)). "
                            + (claudeCheck?.detail ?? "Checking"))

                    HStack(spacing: Spacing.lg) {
                        // Offered only when there is something to fix. A sign-in
                        // button on an already-signed-in row invites a trip to a
                        // terminal that had no purpose.
                        if claudeCheck?.state != .ok {
                            action("Open Terminal and sign in") { signIn() }
                        }
                        action(isCheckingClaude ? "Checking…" : "Check again") {
                            Task { await refreshClaudeCheck() }
                        }
                        .disabled(isCheckingClaude)
                    }
                }
            }
        }
        .task { await refreshClaudeCheck() }
    }

    /// Run `claude` in Terminal.
    ///
    /// The app cannot perform the OAuth itself and should not pretend to: the
    /// subscription credential belongs to the CLI, which is the whole reason
    /// notes cost quota rather than API credit. Claude Code prompts for sign-in
    /// on its own when it starts unauthenticated, so launching it *is* the
    /// remedy — there is no argument to pass, because `/login` is typed inside
    /// its prompt rather than on the command line.
    ///
    /// Opening the binary *with* Terminal rather than writing a temporary
    /// `.command` file: no script to leave behind, no executable bit to set, and
    /// no AppleScript, which would need an automation entitlement and a consent
    /// prompt for a job that is one `open -a` underneath.
    private func signIn() {
        guard let binary = session.settings.claudePath ?? ClaudeRunner.locate(),
            let terminal = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open(
            [binary], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Re-probe. `Preflight.claudeCheck` spawns the CLI and makes one real model
    /// call, which is the only way to tell "installed" from "signed in" — so it
    /// is run on appear and on request, never on every keystroke.
    private func refreshClaudeCheck() async {
        guard !isCheckingClaude else { return }
        isCheckingClaude = true
        defer { isCheckingClaude = false }
        claudeCheck = await Preflight.claudeCheck(settings: session.settings)
    }

    /// What the app finds on its own when no path is set. Naming the located
    /// binary is the difference between "nothing is configured" and "this is the
    /// one it will run" — opposite states behind the same empty field.
    private var locatedDefault: String {
        ClaudeRunner.locate()
            .map { "Found at \($0.path(percentEncoded: false))" }
            ?? "Not found on this Mac. Install it, or point at it here."
    }

    // MARK: - Re-importing the CLI's config

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // "The CLI" is ambiguous on this sheet: the section above is about the
            // claude CLI, and this one is about the separate lecture-notes CLI
            // that writes the config file named below.
            head("The lecture-notes CLI")

            prose("Every field above can be read back from the config file that the CLI writes, for anyone who set it up after installing the app.", tone: Palette.inkSoft)

            Text(ConfigImport.defaultPath.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if confirmingImport {
                // Destructive in the same sense as removing a mirror, and set the
                // same way: it replaces every field above, including the ones the
                // config file never mentions.
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text("✕").font(Typography.ui).foregroundStyle(Palette.stamp)
                    prose("Everything above is replaced by what that file says.", tone: Palette.ink)
                }
                HStack(spacing: Spacing.lg) {
                    action("Import it") { runImport() }
                    action("Leave this alone") { confirmingImport = false }
                }
            } else {
                action("Import from config.toml") {
                    importFailure = nil
                    confirmingImport = true
                }
            }

            if let importFailure {
                prose(importFailure, tone: Palette.ink)
            }
        }
    }

    private func runImport() {
        confirmingImport = false
        guard let imported = ConfigImport.settings() else {
            // `settings(at:)` returns nil both for a missing file and for one
            // carrying no vault, and the two are not worth distinguishing: the
            // remedy is that same file either way.
            importFailure = "Nothing to import. That file is missing, or names no vault."
            return
        }
        importFailure = nil
        session.settings = imported
        SettingsStore.save(imported)
    }

    // MARK: - Persistence

    /// One write path for every control here: mutate, publish, persist.
    ///
    /// Persisting on each committed change rather than behind a Done button,
    /// because this sheet has no Done button — and a settings screen that loses
    /// the vault you just chose when the app quits is worse than one that writes
    /// to `UserDefaults` a few times more than it strictly needs to.
    private func update(_ change: (inout LectureSettings) -> Void) {
        var settings = session.settings
        change(&settings)
        session.settings = settings
        SettingsStore.save(settings)
    }

    /// Every mirror edit is addressed by position, and a position can go stale: a
    /// field commits on blur, from the render before whatever moved the focus,
    /// and that may have been the removal of the mirror it names. Out of range
    /// means the edit has no target left, which is not a reason to trap.
    private func updateMirror(_ index: Int, _ change: (inout MirrorTarget) -> Void) {
        update {
            guard $0.mirrors.indices.contains(index) else { return }
            change(&$0.mirrors[index])
        }
    }

    // MARK: - Rows

    /// A section head is a caption line over a hairline, never a tracked
    /// uppercase eyebrow (§5.1). The rule takes `xl` above and `lg` below,
    /// because a rule reads heavier than the space it occupies (§4).
    private func head(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: Spacing.hair)
            Text(title)
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)
                .padding(.top, Spacing.lg)
        }
        .padding(.top, Spacing.xl)
        .accessibilityAddTraits(.isHeader)
    }

    /// `named` defaults to the visible label and is overridden where the label
    /// alone is ambiguous.
    ///
    /// Two mirrors put three fields called "Courses folder" and three called
    /// "Lectures folder" in the rotor, which is the same collision the model
    /// fields had — and there the label column disambiguates visually while the
    /// rotor is a flat list with nothing else to go on.
    private func textRow(
        _ label: String, value: String, prompt: String, hint: String? = nil,
        named: String? = nil,
        commit: @escaping (String) -> Void
    ) -> some View {
        Row(label: label, hint: hint) {
            field(value, named: named ?? label, prompt: prompt) { text in
                commit(text)
                return text
            }
        }
    }

    /// `named` is the control's accessible name: the label column carries it
    /// visually, but a bare tick in the accessibility tree names nothing.
    private func markRow(
        _ label: String, isOn: Bool, named: String, hint: String,
        commit: @escaping (Bool) -> Void
    ) -> some View {
        Row(label: label, hint: hint) {
            MarkToggle(label: named, isOn: isOn, set: commit)
        }
    }

    /// `named` is the field's accessible name. Without it the placeholder is the
    /// only name a field has, which left three model fields all called "sonnet"
    /// and the two recording fields called "180" and "40" — the label column
    /// carries the distinction visually and nothing carried it to VoiceOver.
    private func field(
        _ value: String, named: String, prompt: String, width: CGFloat? = nil,
        commit: @escaping (String) -> String
    ) -> some View {
        FieldText(
            value: value, name: named, prompt: prompt,
            width: width ?? Self.fieldWidth, commit: commit)
    }

    /// A chosen path and the button that changes it. The path is this control's
    /// value, so it is set in the typed face and stays selectable.
    private func pathControl(
        url: URL?, placeholder: String = "", choose: String, named: String,
        pick: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(url?.path(percentEncoded: false) ?? placeholder)
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(url == nil ? Palette.inkSoft : Palette.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: Self.fieldWidth, alignment: .leading)
                .accessibilityLabel(named)
                .accessibilityValue(url?.path(percentEncoded: false) ?? placeholder)
            action(choose, run: pick)
        }
    }

    /// Plain text, not a bordered button — the reader's action bar sets the same
    /// voice, because the sheet is what is being looked at, not its chrome.
    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(Typography.ui).foregroundStyle(Palette.inkSoft)
        }
        .buttonStyle(.plain)
    }

    private func prose(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(Typography.ui)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Spacing.measure, alignment: .leading)
    }

    /// The app is not sandboxed — it spawns `claude` and writes to vaults outside
    /// any container — so the panel's URL is directly usable and there is no
    /// bookmark to resolve or keep.
    private func pick(directories: Bool, startingAt current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.directoryURL = directories ? current : current?.deletingLastPathComponent()
        // `claude` installs into `~/.claude/local` and other dot-directories,
        // which are otherwise unreachable in the panel.
        panel.showsHiddenFiles = !directories
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Row

/// One determination: what it is on the left, what it is set to on the right.
///
/// The columns are separated by space rather than by a divider, and the hint
/// hangs under the control at the measure. Nothing here is boxed.
private struct Row<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: Content

    /// Holds the longest label at `ui` on one line and leaves the wrap for
    /// accessibility text sizes rather than for ordinary ones.
    private static var labelColumn: CGFloat { Spacing.mount * 2 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xl) {
            Text(label)
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.labelColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                content
                if let hint {
                    Text(hint)
                        .font(Typography.ui)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Spacing.measure, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Text field

/// A field that holds its own draft and commits it on Return or on blur.
///
/// Committing per keystroke would persist "/Users/me/Vau" as a vault path, and
/// every scan keyed off that path then walks a directory that does not exist.
/// `commit` returns what was actually stored, so a rejected edit — an
/// unparseable number, a duplicate frontmatter key — snaps the field back
/// instead of leaving it showing a change that never happened.
private struct FieldText: View {
    let value: String
    /// Not drawn: the row's label column carries this visually. It is here so the
    /// field has an accessible name that is not its placeholder.
    let name: String
    let prompt: String
    let width: CGFloat
    let commit: (String) -> String

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        value: String, name: String, prompt: String, width: CGFloat,
        commit: @escaping (String) -> String
    ) {
        self.value = value
        self.name = name
        self.prompt = prompt
        self.width = width
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.plain)
            // The typed face: paths, subdirectory names and model aliases are the
            // determination slip's own material (§3).
            .font(Typography.code)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            // A `wash` fill with the hairline beneath it. `rule` is never the sole
            // boundary of an interactive control (§2), so the fill carries the
            // field and the rule only closes it.
            .background(Palette.wash)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: Spacing.hair)
            }
            // `.plain` draws no bezel and therefore no focus ring, so a sheet of
            // these gave a keyboard user no way to see which field Tab had
            // reached. Drawn as the doubled plate rule the rest of the system
            // uses rather than as a colour change (PRODUCT.md, Accessibility):
            // `plate` is a legal boundary on `wash` in both appearances, worst
            // 3.19:1. The gap is `hair` rather than `plateBorderGap`, which at
            // 6pt is most of a field's height.
            .overlay {
                if isFocused {
                    ZStack {
                        Rectangle()
                            .strokeBorder(Palette.plate, lineWidth: Spacing.plateBorderOuter)
                        Rectangle()
                            .strokeBorder(Palette.rule, lineWidth: Spacing.plateBorderInner)
                            .padding(Spacing.plateBorderOuter + Spacing.hair)
                    }
                }
            }
            .frame(maxWidth: width, alignment: .leading)
            .focused($isFocused)
            .accessibilityLabel(name)
            .onSubmit { draft = commit(draft) }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft = commit(draft) }
            }
            // The value can change under this field while it is focused: a config
            // re-import rewrites every setting at once, and removing a mirror
            // shifts the one below it up into this row.
            //
            // The obvious `if !isFocused` guard is wrong, and it inverts the whole
            // point. A `.plain` button on macOS does not take first responder, so
            // clicking one never blurs this field — click into "Live model", type
            // `son`, click the `opus` chip, then click away, and the blur commits
            // the abandoned draft over the chip's value. `claude --model son` is
            // then rejected at the end of a recorded lecture. Same shape for an
            // import: whatever half-typed text was sitting in a focused field
            // silently overwrites the setting that was just imported.
            //
            // So a write from elsewhere wins outright and takes the draft with it.
            // Losing a few typed characters when something else changed the same
            // setting is the correct trade against writing them over it.
            .onChange(of: value) { _, latest in
                draft = latest
            }
    }
}

// MARK: - Toggle

/// A tick in a box, drawn rather than borrowed.
///
/// `Toggle` fills in the system accent colour, and this palette has exactly one
/// pigment with three named uses, none of which is a checkbox (§2). State is
/// carried by the tick and by the word beside it, and by neither's colour.
private struct MarkToggle: View {
    /// Not drawn: the row's label column carries this visually. It is here so the
    /// control has an accessible name of its own.
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Rectangle().fill(Palette.wash)
                    Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair)
                    if isOn {
                        Text("✓").font(Typography.ui).foregroundStyle(Palette.ink)
                    }
                }
                .frame(width: Spacing.lg, height: Spacing.lg)

                Text(isOn ? "Yes" : "No")
                    .font(Typography.caption.smallCaps())
                    .tracking(Typography.captionTracking)
                    .foregroundStyle(Palette.inkSoft)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Yes" : "No")
    }
}
