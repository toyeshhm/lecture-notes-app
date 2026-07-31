import Foundation
import LectureKit
import SwiftUI

/// The things you can do to a lecture you are reading.
///
/// Set in the board margin above the sheet, alongside the way back. Nothing that
/// is not the note goes inside the plate border, so these are chrome sharing the
/// board with the caption line rather than a toolbar mounted on the specimen.
///
/// Every control here is absent rather than disabled when it does not apply. A
/// greyed-out "Play recording" on a lecture recorded with `keepAudio` off asks a
/// question the user cannot answer from looking at it; nothing at all says the
/// same thing without the invitation.
struct LectureActionBar: View {

    let entry: LibraryLecture

    /// Called after a re-run rewrites the file, so the reader re-reads it.
    let reload: () -> Void

    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var player = LecturePlayer()
    @State private var rerun: Rerun = .idle
    @State private var openedTo: LectureActions.OpenOutcome?

    /// A re-run is a long call to a model followed by an overwrite of a file the
    /// user may have edited by hand in Obsidian, so it is two steps with the
    /// markdown held in between.
    private enum Rerun: Equatable {
        case idle
        case running
        /// Written and waiting for the user to accept or discard it.
        case ready(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.lg) {
                action("Open in Obsidian") { openedTo = LectureActions.open(entry) }
                action("Reveal in Finder") { LectureActions.reveal(entry) }
                if entry.audioURL != nil { playControl }
                if LectureActions.canRerun(entry) { rerunControl }
            }
            status
        }
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: rerun)
        // A player holding an open file on a vault that is being unmounted, or a
        // lecture left playing while another is opened, both end here.
        .onDisappear { player.stop() }
    }

    // MARK: Controls

    /// Plain text, not a bordered button. §5.3 sets Stop as "a plain push
    /// button"; on the board these are quieter still, because the note is the
    /// thing being looked at.
    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
        }
        .buttonStyle(.plain)
    }

    private var playControl: some View {
        HStack(spacing: Spacing.sm) {
            // The word names the act, not the state, and it is the same word
            // Voice Control has to hear: "Pause recording" while it is playing,
            // "Play recording" while it is not.
            action(player.isPlaying ? "Pause recording" : "Play recording") { player.toggle(entry) }
            if player.duration > 0 {
                // Tabular, so the reading does not twitch a word sideways every
                // second while you are trying to read past it.
                Text("\(SessionModel.clock(player.currentTime)) / \(SessionModel.clock(player.duration))")
                    .font(Typography.micro)
                    .tracking(Typography.microTracking)
                    .foregroundStyle(Palette.inkSoft)
                    // "47:22" read literally is "four seven colon two two", and a
                    // raw second count is worse still: a 47-minute lecture came
                    // out as "2842 seconds of 2842". Spelled in units instead,
                    // the way `SessionModel.spokenElapsed` spells the capture
                    // sheet's clock.
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(spoken(player.currentTime)) of \(spoken(player.duration))")
            }
        }
    }

    /// A playback time in words. Seconds are kept: a listener scrubbing by ear
    /// needs them, and this is a readout rather than a duration on a label.
    private func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    @ViewBuilder private var rerunControl: some View {
        switch rerun {
        case .idle, .failed:
            action("Write the notes again") { start() }
        case .running:
            Text("Writing with \(session.settings.finalModel)…")
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
        case .ready:
            // The destructive half. `ink` copy with the cinnabar carried by the
            // stamp glyph alone (DESIGN.md §5.3): the pigment marks the act, it
            // does not colour the sentence describing it.
            HStack(spacing: Spacing.sm) {
                // The mark, not a word: what it means is in the sentence below
                // it and in the button beside it, so spoken it is noise.
                Text("✕")
                    .foregroundStyle(Palette.stamp)
                    .accessibilityHidden(true)
                action("Replace the note") { accept() }
                action("Keep the old one") { rerun = .idle }
            }
            .font(Typography.ui)
        }
    }

    /// One line under the controls, for the things that have to be said in words.
    @ViewBuilder private var status: some View {
        switch (rerun, openedTo) {
        case (.failed(let why), _):
            note(why)
        case (.ready, _):
            note("The new notes overwrite this file. Anything you edited in Obsidian goes with it.")
        // Which application actually opened is not obvious from a window that
        // came forward behind this one, and the fallback is a different action
        // from the one that was asked for.
        case (_, .finder(let reason)):
            note("Opened in Finder instead. \(reason)")
        default:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Re-running

    private func start() {
        rerun = .running
        let settings = session.settings
        Task {
            do {
                rerun = .ready(try await LectureActions.rerun(entry, settings: settings))
            } catch let failure as LectureActions.RerunFailure {
                rerun = .failed(describe(failure))
            } catch let failure as LectureKitError {
                rerun = .failed(SessionModel.describe(failure))
            } catch {
                rerun = .failed(error.localizedDescription)
            }
        }
    }

    private func accept() {
        guard case .ready(let markdown) = rerun else { return }
        do {
            try LectureActions.apply(markdown, to: entry)
            rerun = .idle
            reload()
        } catch {
            rerun = .failed("Couldn't write the note: \(error.localizedDescription)")
        }
    }

    private func describe(_ failure: LectureActions.RerunFailure) -> String {
        switch failure {
        case .unreadable:
            return "Couldn't read the note. It may have been moved or the vault unmounted."
        case .noTranscript:
            return "This copy has no transcript, so there is nothing to write from."
        }
    }
}
