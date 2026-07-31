import AppKit
import LectureKit
import SwiftUI

/// The determination slip: what was checked before the first lecture, and what
/// was found.
///
/// **Not a wizard.** Every `Preflight` check is independent of the others and can
/// be fixed in any order, so there is no step counter, no Next button and no
/// enforced sequence — a slip is filled in wherever the determinations land.
/// Warnings never block dismissal either: "macOS will ask the first time you
/// record" is the correct state for a new install and cannot be resolved from
/// here, so a screen that refused to close on it would be unclosable.
///
/// Only `.fail` means a recording produces no note, and the summary line says so
/// by name rather than by colour.
///
/// **The pigment stays in its box.** `DESIGN.md` §2 gives cinnabar exactly three
/// jobs — the live recording indicator, the type-specimen mark, and destructive
/// confirmations. A failing check is none of the three, so state here is carried
/// by shape (filled disc, hollow ring, cross) and by the word beside it, both of
/// which survive greyscale and both of which reach the accessibility tree.
struct FirstRunView: View {

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var checks: [Preflight.Check] = []
    @State private var isChecking = false
    @State private var isDownloadingModels = false
    /// The batch currently in flight, so a remedy can supersede it.
    @State private var running: Task<[Preflight.Check], Never>?

    /// A ScrollView reports a flexible ideal height, so presented as a sheet this
    /// would mount as a strip and scroll a slip that fits. The floor is the prose
    /// measure plus one mount, which clears the five rows plus header and footer.
    private static let minimumHeight = Spacing.measure + Spacing.mount

    var body: some View {
        ScrollView {
            // The slip is a fixed measure; the board is not. Without this the
            // scroll content sizes to the slip and the board stops where it
            // stops, leaving bare window either side of it whenever the sheet is
            // wider than its content.
            slip.padding(Spacing.xl).frame(maxWidth: .infinity)
        }
        .frame(minHeight: Self.minimumHeight)
        .background(BoardBackground())
        // On the way out rather than on the button, because Escape dismisses a
        // sheet too: recorded there, the slip would come back next launch for
        // anyone who closed it the way macOS closes everything else.
        .onDisappear { Self.markSeen() }
        .task { await runChecks() }
        // System Settings, a terminal and the file panel are all somewhere else,
        // so coming back is the moment a remedy has just been applied. A slip
        // still showing the failure the user has just fixed is worse than no
        // slip, and this screen is short-lived enough that re-probing `claude` on
        // reactivation stays bounded.
        // Only for the microphone, and only while it is unresolved. Every other
        // remedy on this slip re-checks itself when it returns, so a blanket
        // re-run on reactivation buys nothing and costs a subprocess spawn plus a
        // billed model call each time — four of them if the user tabs to System
        // Settings and back four times, which is what working through a remedy
        // looks like. The microphone is the one switch that is flipped somewhere
        // else with nothing coming back to tell us.
        .onChange(of: scenePhase) { previous, current in
            guard previous != .active, current == .active,
                  checks.first(where: { $0.id == "microphone" })?.state != .ok
            else { return }
            Task { await runChecks() }
        }
        .sheet(isPresented: $isDownloadingModels) {
            ModelDownloadView()
        }
        // Not `onDismiss:` on the sheet above: the download can also finish while
        // the sheet is still up, and this catches both.
        .onChange(of: isDownloadingModels) { _, showing in
            guard !showing else { return }
            Task { await runChecks() }
        }
    }

    // MARK: The slip

    private var slip: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            hairline

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { hairline }
                CheckRow(
                    row: row,
                    remedy: { remedy(for: row) })
            }

            hairline
            footer
        }
        // Fixed at the measure rather than `maxWidth`: this is what gives the
        // sheet an ideal width to size itself from, and it holds the detail lines
        // inside the 65–75 character band while they wrap.
        .frame(width: Spacing.measure, alignment: .leading)
        // The sheet fill sits outside the frame, per `PlateFrame`'s contract:
        // mounted inside it the border band would be board, grain and all.
        .plateFrame(padding: Spacing.xl)
        .background(Palette.sheet)
        .animation(Motion.mount.animation(reduceMotion: reduceMotion), value: checks)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Determination")
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)

            Text("What a recording needs")
                .font(Typography.h2)
                .tracking(Typography.h2Tracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)

            Text(summary)
                .font(Typography.bodyText)
                .foregroundStyle(Palette.inkSoft)
                .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Button("Check again") { Task { await runChecks() } }
                .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
                .disabled(isChecking)
                .accessibilityHint("Runs every check again")

            Spacer(minLength: Spacing.md)

            Button(blocking.isEmpty ? "Continue" : "Continue anyway") { dismiss() }
            .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
            // Return closes the slip only when nothing on it blocks a recording.
            // Bound unconditionally, the one key everyone presses to get past a
            // dialog would skip the failures this screen exists to state.
            // ...and never while a check is in flight, when `blocking` still holds
            // the answer from before the thing the user just fixed.
            .keyboardShortcut(blocking.isEmpty && !isChecking ? KeyboardShortcut.defaultAction : nil)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: Spacing.hair)
            .accessibilityHidden(true)
    }

    // MARK: Remedies
    //
    // Each appears only while its own check is not `.ok`, and every one of them
    // re-runs the checks when it returns.

    @ViewBuilder private func remedy(for row: Row) -> some View {
        switch (row.id, row.state) {
        case ("microphone", .fail):
            if let pane = Self.microphonePane {
                // The URL lands on the Microphone list, not on the pane's root, so
                // the label names where the button actually goes. The check's own
                // detail line already gives the full path through System Settings.
                Button("Open the Microphone list") { NSWorkspace.shared.open(pane) }
                    .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityHint("Opens System Settings at Privacy & Security, scrolled to the microphone switches")
            }

        case ("vault", .fail):
            Button("Choose another vault…") { chooseVault() }
                .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
                .accessibilityHint("Picks the folder your notes are filed into")

        // The check reports "not found" and "signed out" under one id, and its
        // detail line is the only thing that separates them. Matching on the
        // command it names is the narrowest hook available: `/login` appears in
        // the signed-out remedy and in no other claude detail.
        case ("claude", .fail), ("claude", .warn):
            if row.detail.contains("/login") {
                signedOutCommand
            } else {
                Button("Locate claude…") { chooseClaude() }
                    .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityHint("Points the app at the claude binary")
            }

        case ("models", .fail), ("models", .warn):
            Button("Download the models…") { isDownloadingModels = true }
                .buttonStyle(SlipButtonStyle(reduceMotion: reduceMotion))
                .accessibilityHint("Fetches the transcription models now instead of mid-lecture")

        default:
            EmptyView()
        }
    }

    /// Signing in happens in a terminal and cannot be done from inside this app,
    /// so the remedy is the two exact lines to type, selectable and set as a code
    /// block (`DESIGN.md` §5.5) because they are literal input rather than prose.
    private var signedOutCommand: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(verbatim: "claude")
            Text(verbatim: "/login")
        }
        .font(Typography.code)
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(Palette.wash)
        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In a terminal, run claude, then type slash login.")
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.settings.vault
        panel.message = "Choose the vault your lecture notes are filed into."
        panel.prompt = "Use Vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var updated = session.settings
        // `Settings.init` normalises the vault path but a direct assignment does
        // not, and relocation tracking is keyed off the normalised form: an
        // unnormalised path here orphans every note already written.
        updated.vault = PathComponent.normalised(url)
        apply(updated)
    }

    private func chooseClaude() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The CLI's own installer puts it in ~/.claude/local, which the panel
        // cannot reach at all with hidden files off.
        panel.showsHiddenFiles = true
        panel.directoryURL = session.settings.claudePath?.deletingLastPathComponent()
        panel.message = "Choose the claude binary."
        panel.prompt = "Use"
        // No content-type filter: some installs ship `claude` as a symlink into a
        // node shim, and a filter on executables hides exactly those.
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var updated = session.settings
        updated.claudePath = url
        apply(updated)
    }

    /// Both stores, in the order that survives a crash: disk first, so a settings
    /// change cannot be live in the running app and absent from the next launch.
    private func apply(_ updated: LectureSettings) {
        SettingsStore.save(updated)
        session.settings = updated
        Task { await runChecks() }
    }

    // MARK: Checks

    /// The determinations, or the blank slip while the first run is out.
    private var rows: [Row] {
        checks.isEmpty ? Self.blankSlip : checks.map(Row.init)
    }

    /// `Preflight` runs its checks concurrently but hands them back as one array,
    /// and the per-check functions are internal to the package, so this screen
    /// cannot mount them one at a time as each resolves. The slip is therefore
    /// ruled before it is filled in: every row is present and named from the
    /// first frame, carrying a pending mark, and the determinations arrive
    /// together when the slow one (spawning `claude`) lands. The ids and titles
    /// are `Preflight.run`'s own, in its own order.
    private static let blankSlip: [Row] = [
        Row(id: "platform", title: "This Mac"),
        Row(id: "microphone", title: "Microphone"),
        Row(id: "claude", title: "Claude CLI"),
        Row(id: "models", title: "Transcription models"),
        Row(id: "vault", title: "Vault"),
    ]

    /// Runs the batch, replacing any run already in flight.
    ///
    /// The obvious guard — return early while a run is in progress — is wrong
    /// here, and wrong in exactly the way this screen exists to prevent. The
    /// claude probe spawns a subprocess with a 30 second timeout, so a run is
    /// live for a long time by UI standards, and every remedy on this slip
    /// finishes by asking for a re-check. Choose a valid vault while the first
    /// run is still blocked on that probe and the re-check is dropped; the
    /// in-flight run, started with the *old* settings, then lands and writes the
    /// stale result back. The slip goes on reporting a vault the user has already
    /// fixed, with nothing left to trigger another look.
    ///
    /// Cancelling and restarting also makes the result unambiguous: whatever
    /// lands was started with the settings in force now.
    private func runChecks() async {
        running?.cancel()
        let settings = session.settings
        let task = Task { await Preflight.run(settings: settings) }
        running = task
        isChecking = true
        let result = await task.value
        // A run that was replaced must not write: it is the older answer, and it
        // finishes *after* the run that superseded it whenever the newer one is
        // faster — which is the common case, because a fixed vault stats quickly.
        guard !task.isCancelled else { return }
        checks = result
        running = nil
        isChecking = false
    }

    private var blocking: [String] {
        checks.filter { $0.state == .fail }.map(\.title)
    }

    /// Says which failures mean a recording produces no note, by name. A count
    /// beside a mark ("4 of 5 ready") is how a blocking failure gets missed.
    private var summary: String {
        if checks.isEmpty { return "Checking what this Mac can do." }
        if blocking.isEmpty {
            return checks.contains(where: { $0.state == .warn })
                // "Notes" is the app's own word for what it writes, so it cannot
                // also mean the lines on this slip.
                ? "Nothing here stops a recording. The warnings below are worth reading once."
                : "Everything a recording needs is in place."
        }
        let names = blocking.formatted(.list(type: .and))
        let verb = blocking.count == 1 ? "is" : "are"
        return "A recording will produce no note until \(names) \(verb) fixed. Everything else can wait."
    }

    /// Opens System Settings at the Microphone list rather than at the pane's
    /// root, which is several scrolls away from the switch that matters.
    private static let microphonePane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    // MARK: - Row

    /// One line of the slip: what was checked, what was found, and how it is put
    /// right. `state` is `nil` until the batch lands.
    fileprivate struct Row: Identifiable {
        let id: String
        let title: String
        let state: Preflight.State?
        let detail: String

        init(id: String, title: String) {
            self.id = id
            self.title = title
            state = nil
            detail = ""
        }

        init(_ check: Preflight.Check) {
            id = check.id
            title = check.title
            state = check.state
            detail = check.detail
        }
    }
}

// MARK: - Presentation

extension FirstRunView {

    /// Namespaced the way `SettingsStore` namespaces its own key, and versioned
    /// for the same reason: a later slip that checks different things is a
    /// different thing to have seen.
    private static let seenKey = "firstRun.seen.v1"

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    /// Whether the slip should be shown at all, for `RootView` to read at launch.
    ///
    /// Two reasons, and only two: it has never been seen, or something that stops
    /// a recording producing a note is failing right now. A warning is not one of
    /// them — the microphone prompt is a warning on every fresh install, and a
    /// screen that reappeared for it would be a screen the user learns to
    /// dismiss unread.
    ///
    /// Never seen is answered without touching the disk or spawning anything, so
    /// the common first launch presents immediately; only a returning launch pays
    /// for the probe, and it does so off the main actor while the window is
    /// already up.
    static func shouldPresent(settings: LectureSettings) async -> Bool {
        if !UserDefaults.standard.bool(forKey: seenKey) { return true }
        // Deliberately not the full batch. Deciding whether to *open* the slip
        // must not spawn `claude` and spend a model call on every launch of an
        // app that is working fine; the two failures that are both blocking and
        // free to detect are enough to earn the interruption, and opening the
        // slip for any reason runs everything.
        return Preflight.vaultCheck(settings: settings).state == .fail
            || Preflight.platform().state == .fail
    }
}

// MARK: - Check row

private struct CheckRow<Remedy: View>: View {
    let row: FirstRunView.Row
    @ViewBuilder let remedy: () -> Remedy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                DeterminationMark(state: row.state)

                Text(row.title)
                    .font(Typography.uiBold)
                    .foregroundStyle(Palette.ink)

                Spacer(minLength: Spacing.sm)

                Text(Self.word(for: row.state))
                    .font(Typography.caption.smallCaps())
                    .tracking(Typography.captionTracking)
                    .foregroundStyle(Palette.inkSoft)
            }
            // Combined so the state is spoken as part of the row's name rather
            // than as a stray word after it. The mark is hidden from the tree, so
            // this reads "Microphone, Blocking" and nothing is said twice.
            .accessibilityElement(children: .combine)

            if !row.detail.isEmpty {
                // The remedy is the whole detail line on a failure, so it wraps to
                // as many lines as it needs. Truncating it to a chip would throw
                // away the only instruction on the screen.
                Text(row.detail)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)   // paths and commands get copied out
            }

            remedy()
        }
        .padding(.vertical, Spacing.xs)
    }

    /// The state in words. This is both the visible mark's caption and the half
    /// of the accessibility label that names the state, so the two cannot drift.
    private static func word(for state: Preflight.State?) -> String {
        switch state {
        case .ok: return "Ready"
        case .warn: return "Warning"
        case .fail: return "Blocking"
        case nil: return "Checking"
        }
    }
}

// MARK: - Determination mark

/// The state as a shape: a filled disc, a hollow ring, a cross, or an empty
/// square while the determination is still out.
///
/// Four marks that stay distinct with the colour thrown away, because the pigment
/// has three documented jobs and none of them is this one (`DESIGN.md` §2). Ring
/// and disc are the capture panel's own idiom for a state that is and is not.
private struct DeterminationMark: View {
    let state: Preflight.State?

    /// The mark sits in an `lg` box so every row's title starts on one line,
    /// whichever shape is drawn — the same box the capture panel's indicator uses.
    private static let box = Spacing.lg

    /// 2pt, spelled as two hairlines rather than as a literal — the idiom the
    /// sidebar's 6pt disc and the capture panel's 10pt one already use.
    private static let inset = Spacing.hair * 2

    var body: some View {
        shape
            .frame(width: Self.box, height: Self.box)
            // The word beside it carries the state to VoiceOver; the mark would
            // only repeat it.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var shape: some View {
        switch state {
        case .ok:
            Circle()
                .fill(Palette.inkSoft)
                .padding(Self.inset)

        case .warn:
            Circle()
                .strokeBorder(Palette.inkSoft, lineWidth: Spacing.plateBorderOuter)
                .padding(Self.inset)

        case .fail:
            // `ink` rather than `inkSoft`: this is the one mark on the slip that
            // has to be findable in a glance down the column, and weight is the
            // only axis left once the pigment is ruled out.
            Cross()
                .stroke(Palette.ink, lineWidth: Spacing.plateBorderOuter)
                .padding(Self.inset)

        case nil:
            // A square, so a pending row is not mistaken for a determined one at
            // a glance: nothing else on the slip is drawn with corners.
            Rectangle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.plateBorderInner)
                .padding(Self.inset)
        }
    }
}

private struct Cross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

// MARK: - Button

/// The slip's control: `wash` inside a 1.5pt `plate` rule, `ui` Charter Bold in
/// `ink`. Never `.borderedProminent`, which would paint the system accent into a
/// palette whose only pigment is cinnabar.
///
/// `MenuBarView` carries the same style as its own private type. Deliberately not
/// shared yet: that one is full-width by contract because the popover has exactly
/// one action, and this one sits inline beside a detail line. The third surface
/// that needs a button is the one that should hoist a parameterised style into
/// `Components/`.
private struct SlipButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.uiBold)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Palette.wash)
            .overlay(Rectangle().strokeBorder(Palette.plate, lineWidth: Spacing.plateBorderOuter))
            // 0.55 is the system's one documented opacity floor (the pulse), so
            // press feedback borrows it rather than inventing a second value.
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Motion.tap.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}


#if DEBUG
extension FirstRunView {
    /// Mounts the slip with checks already determined.
    ///
    /// The snapshot tool renders in a fixed run-loop window, and a real
    /// `Preflight.run` spawns `claude` — so every render caught the slip in its
    /// pending state and no resolved mark was ever reviewed. This is the seam.
    init(preview checks: [Preflight.Check]) {
        self.init()
        _checks = State(initialValue: checks)
    }
}
#endif
