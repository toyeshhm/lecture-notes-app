import FluidAudio
import Foundation
import LectureKit
import SwiftUI

// MARK: - The download itself

/// The first-run fetch of the Parakeet CoreML models, as something a sheet can
/// watch.
///
/// `Transcriber.loadModels()` does this download inline, from `SessionModel
/// .start()`, which means the very first press of record sits on "Loading the
/// transcriber…" for as long as the connection takes — with a lecture already
/// under way. This object exists to spend that time somewhere it costs nothing.
///
/// **What FluidAudio actually reports.** Its `ProgressHandler` number is real:
/// `ProgressReporter.downloadFraction` weights it by bytes across every file in
/// the repository, falling back to file counts only when Hugging Face gives no
/// sizes. So the bar is measured. Two properties of it had to be handled rather
/// than assumed:
///
/// 1. `fractionCompleted` spans the whole load, of which the download is only
///    the first half — `ModelHub` builds its reporter with
///    `downloadPhaseWeight: 0.5` and gives the rest to CoreML compilation. Raw,
///    the bar would stall at 50% for the entire compile.
/// 2. `AsrModels.download` calls `ModelHub.loadModels` once per model file and
///    each call restarts its fraction at zero. The first already fetches the
///    whole required set (`loadModelsOnce` downloads the repo's entire model
///    list, not just the file asked for), so the rest hit the cache and replay
///    0 → 1 instantly. Raw, the bar would run backwards three times.
///
/// Hence ``Stage`` is `Comparable` and only moves forward.
@MainActor
@Observable
final class ModelDownload {

    /// Ordered: progress may only move forward. Case order is the order, and
    /// `Comparable` is synthesised from it.
    enum Stage: Comparable {
        /// Asking the repository what it holds. No bytes have moved yet.
        case checking
        /// Byte-weighted fraction of the download, 0…1. Measured, not modelled.
        case downloading(Double)
        /// On disk. CoreML is specialising the models for this Mac.
        case preparing

        /// Whether moving here from `other` would change what is on screen.
        ///
        /// Only the drawn precision counts. The bar and the percentage are both
        /// whole numbers, so a fraction that moved by four ten-thousandths is a
        /// redraw of identical pixels — and at one callback per network chunk
        /// that is most of them.
        func isDistinct(from other: Stage) -> Bool {
            switch (self, other) {
            case (.downloading(let new), .downloading(let old)):
                return Int(new * 100) != Int(old * 100)
            case (.checking, .checking), (.preparing, .preparing):
                return false
            default:
                return true
            }
        }
    }

    enum State {
        case idle
        case running(Stage)
        case done
        case failed(Failure)
    }

    struct Failure {
        /// What went wrong, in a sentence that names something to do about it.
        let reason: String
        /// The framework's own words. Kept because a reason a user cannot act
        /// on is still the reason a bug report needs.
        let detail: String
    }

    private(set) var state: State
    /// Bytes the cached models occupy, once measured. `nil` while unknown.
    private(set) var sizeOnDisk: Int64?
    /// When the current run began, for the elapsed figure.
    private(set) var startedAt: Date?

    private var run: Task<Void, Never>?

    /// The parameters default to `.idle`; the rest exist so previews and the
    /// snapshot tool can mount a running or failed sheet, which otherwise takes
    /// a real network fault to produce.
    init(state: State = .idle, sizeOnDisk: Int64? = nil, startedAt: Date? = nil) {
        self.state = state
        self.sizeOnDisk = sizeOnDisk
        self.startedAt = startedAt
    }

    // MARK: Constants

    /// Must match `Transcriber`'s version, and `encoderPrecision` must stay at
    /// FluidAudio's default for the same reason: `modelsAreCached` asks whether
    /// *that* repo at *that* precision is on disk, so any other combination
    /// downloads, reports success and leaves the app exactly as cold.
    private static let version: AsrModelVersion = .v3

    /// `ModelHub.loadModelsOnce` builds its reporter with this weight. Dividing
    /// by it converts the library's whole-operation fraction into the fraction
    /// of the *download* this screen claims to be showing.
    private static let downloadPhaseWeight = 0.5

    private static var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    // MARK: Running

    func start() {
        guard run == nil else { return }
        state = .running(.checking)
        startedAt = .now
        // `self` is captured strongly on purpose. Dismissing the sheet part-way
        // should finish the download, not abandon a half-fetched cache; the
        // task releases the object when it ends, and `cancel()` is the way out.
        run = Task {
            do {
                // The models are discarded and the load is still worth waiting
                // for: `AsrModels.download` alone satisfies `modelsAreCached`,
                // but the first `MLModel` instantiation of an ANE model is its
                // own multi-second specialisation pass, and that pass is the
                // other half of what record time otherwise spends.
                _ = try await AsrModels.downloadAndLoad(
                    version: Self.version,
                    progressHandler: { progress in
                        // Called on whatever queue the downloader is on, and
                        // each hop is its own task, so two can land out of
                        // order. `absorb` only moves forward, which is what
                        // makes that harmless rather than a stutter.
                        Task { @MainActor in self.absorb(progress) }
                    })
                try Task.checkCancellation()
                self.state = Self.settled()
                await self.refresh()
            } catch {
                // A cancelled run is not a failure and has nothing to report.
                self.state = Self.wasCancelled(error)
                    ? .idle
                    : .failed(Self.explain(error))
            }
            self.run = nil
        }
    }

    /// Real, not decorative: `FileDownloader` wraps its transfer in
    /// `withTaskCancellationHandler`, and `ModelHub.loadModels` tells
    /// cancellation from corruption, so this costs the file in flight and
    /// leaves every completed one in the cache.
    func cancel() {
        run?.cancel()
    }

    /// Re-reads what is actually on disk. Cheap enough to call on appear.
    func refresh() async {
        if Transcriber.modelsAreCached {
            if case .idle = state { state = .done }
            let directory = Self.cacheDirectory
            sizeOnDisk = await Task.detached { cacheSize(of: directory) }.value
        } else {
            sizeOnDisk = nil
        }
    }

    // MARK: Progress

    private func absorb(_ progress: DownloadProgress) {
        guard case .running(let stage) = state else { return }
        let reported: Stage
        switch progress.phase {
        case .listing:
            reported = .checking
        case .downloading:
            reported = .downloading(Self.fraction(of: progress.fractionCompleted))
        case .compiling:
            reported = .preparing
        }
        let next = max(stage, reported)

        // `StreamingDownloadDelegate` calls back on every `didReceive data:`,
        // which for a 600 MB fetch in 4–64 KB chunks is tens of thousands of
        // callbacks. Each one was a main-actor hop, an `@Observable` write and a
        // SwiftUI invalidation that restarted the bar's 0.14s settle animation —
        // so the screen whose one job is to stay responsive enough to be
        // cancelled was saturating the main thread doing it. Nothing below the
        // percent is drawn, so nothing below the percent is worth a frame.
        //
        // The stage comparison still has to run: `.downloading → .preparing` is a
        // change of kind, not of magnitude, and dropping it would leave the
        // caption reading "Downloading" through the whole compile.
        guard next.isDistinct(from: stage) else { return }
        state = .running(next)
    }

    /// `fractionCompleted` arrives from a JSON-derived byte total, so a zero or
    /// missing size can make it non-finite. A NaN here would propagate into the
    /// drawn geometry and into `Comparable`, where it compares false against
    /// everything and would freeze the stage.
    private static func fraction(of reported: Double) -> Double {
        let scaled = reported / downloadPhaseWeight
        guard scaled.isFinite else { return 0 }
        return min(max(scaled, 0), 1)
    }

    // MARK: Outcome

    /// Verifies the claim this screen exists to make. The download runs against
    /// `AsrModels` directly while `SessionModel` goes through `Transcriber`, so
    /// a version or precision that drifted apart would otherwise show a
    /// completed download and still leave the first recording to fetch its own.
    private static func settled() -> State {
        guard Transcriber.modelsAreCached else {
            return .failed(Failure(
                reason: "The download finished, but the transcriber cannot find the models where it looks for them.",
                detail: cacheDirectory.path(percentEncoded: false)))
        }
        return .done
    }

    /// Cancellation arrives as `CancellationError`, as `URLError.cancelled`, or
    /// buried under a `DownloadError`; FluidAudio checks the same three.
    private static func wasCancelled(_ error: Error) -> Bool {
        chain(error).contains { step in
            let ns = step as NSError
            return step is CancellationError
                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
                || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
        }
    }

    /// Names the failure. Every one of these is ordinary — a hall with no
    /// signal, a campus network that wants a login first, a full disk — and
    /// each has a different thing to do next, so "download failed" is not an
    /// answer. The framework's own words are kept whichever sentence wins.
    private static func explain(_ error: Error) -> Failure {
        for step in chain(error) {
            if let named = reason(for: step) {
                return Failure(reason: named, detail: error.localizedDescription)
            }
        }
        return Failure(
            reason: "The download did not finish.", detail: error.localizedDescription)
    }

    private static func reason(for error: Error) -> String? {
        if let download = error as? DownloadError {
            switch download {
            case .htmlErrorResponse:
                // A sign-in page served where a model file was asked for is
                // what a captive portal looks like from here.
                return "The network answered with a web page instead of the download. That is usually a wifi login that has not been completed yet. Open a browser, sign in to the network, then try again."
            case .rateLimited:
                return "Hugging Face is rate-limiting this Mac. Waiting a few minutes normally clears it."
            case .networkDisabled, .modelMissing:
                return "The transcriber is in offline mode, so it will not fetch anything."
            case .invalidArtifact:
                return "A downloaded file arrived damaged and was refused. Trying again fetches it fresh."
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, Self.offlineCodes.contains(nsError.code) {
            return "This Mac is not online. The models come from Hugging Face, so this needs a connection once."
        }
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "The connection timed out. On a slow network this can take several attempts; whole files already fetched are kept."
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)):
            return "There is not enough room on this disk. The models need a few hundred megabytes free."
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError):
            return "The models folder cannot be written to: \(cacheDirectory.path(percentEncoded: false))"
        default:
            return nil
        }
    }

    /// Nothing reached: no route to the host at all.
    private static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
    ]

    /// The wrapping chain, outermost first. `DownloadError` is a Swift enum, so
    /// its `underlying` is not reachable through `NSUnderlyingErrorKey` and has
    /// to be unwrapped by pattern; everything else nests the ordinary way. The
    /// bound stops a self-referential chain from spinning.
    private static func chain(_ error: Error) -> [Error] {
        var chain: [Error] = []
        var current: Error? = error
        while let step = current, chain.count < 8 {
            chain.append(step)
            if case DownloadError.downloadFailed(_, let underlying) = step {
                current = underlying
            } else {
                current = (step as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            }
        }
        return chain
    }
}

/// Bytes the cached models occupy. Allocated size rather than logical size: a
/// `.mlmodelc` is a directory of many small files and the figure the user will
/// compare against Finder is the one the filesystem actually spends.
private func cacheSize(of directory: URL) -> Int64? {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
    guard let walk = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return nil }

    var total: Int64 = 0
    for case let url as URL in walk {
        let values = try? url.resourceValues(forKeys: Set(keys))
        total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
    return total > 0 ? total : nil
}

// MARK: - The sheet

/// One mounted sheet on the board: what the models are, what state the download
/// is in, and the single action that changes it.
struct ModelDownloadView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var download: ModelDownload

    init(download: ModelDownload = ModelDownload()) {
        _download = State(initialValue: download)
    }

    var body: some View {
        ZStack {
            BoardBackground()
            sheet
                .frame(width: Spacing.measure)
                .plateFrame(padding: Spacing.sheetPadding)
                .background(Palette.sheet)
                .plateMark()
                .padding(Spacing.plate)
        }
        .task { await download.refresh() }
        // Escape means "leave this sheet", never "abandon the download" — every
        // state's `.cancelAction` button already dismisses rather than cancels.
        // Bound here because `.done` has one button and it holds `.defaultAction`,
        // so Escape had nothing to trigger on the state the sheet opens in
        // whenever the models are already cached.
        .onExitCommand { dismiss() }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            plateRule
            content(for: download.state)
            plateRule
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Transcription models")
                .font(Typography.h2)
                .tracking(Typography.h2Tracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            SpecimenLabel(title: "Parakeet TDT v3 · speech recognised on this Mac", detail: sizeLine)
        }
    }

    /// The determination line's typed half doubles as the answer to "what is the
    /// app holding on my disk", which is only knowable once something is cached.
    private var sizeLine: String? {
        download.sizeOnDisk.map { "\($0.formatted(.byteCount(style: .file))) on disk" }
    }

    /// A rule reads heavier than the space it occupies, so it takes `xl` above
    /// and `lg` below — the stack's own spacing supplies the `lg`.
    private var plateRule: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: Spacing.hair)
            .padding(.top, Spacing.sm)
            .accessibilityHidden(true)
    }

    // MARK: Body, per state

    @ViewBuilder
    private func content(for state: ModelDownload.State) -> some View {
        switch state {
        case .idle:
            prose(
                """
                Speech is recognised on this Mac, so the models have to be here \
                before a lecture starts. They are a few hundred megabytes and \
                they download once. Fetching them now is the difference between \
                pressing record and recording, and pressing record and waiting \
                on the hall's wifi.
                """)

        case .running(let stage):
            VStack(alignment: .leading, spacing: Spacing.md) {
                HatchBar(fraction: fraction(of: stage))
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(caption(for: stage))
                        .font(Typography.ui)
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: Spacing.sm)
                    elapsed
                }
                prose("Whole files that have already downloaded are kept, so a cancelled or dropped download resumes rather than restarts.")
            }

        case .done:
            prose("The models are on this Mac. Recording now starts the moment you press record.")

        case .failed(let failure):
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(failure.reason)
                    .font(Typography.runIn)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.detail)
                    .font(Typography.micro)
                    .tracking(Typography.microTracking)
                    .foregroundStyle(Palette.inkSoft)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(Typography.bodyText)
            .foregroundStyle(Palette.inkSoft)
            .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one genuinely long-running thing in the app, so the figure that says
    /// it is still moving is worth its own tick.
    @ViewBuilder
    private var elapsed: some View {
        if let startedAt = download.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = context.date.timeIntervalSince(startedAt)
                Text(SessionModel.clock(seconds))
                    .font(Typography.micro)
                    .tracking(Typography.microTracking)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSoft)
                    // Tabular figures are for the eye; "1:04" read literally is
                    // "one colon zero four", so the spoken form is spelled out —
                    // the same swap `SessionModel.spokenElapsed` makes for the
                    // capture panel's clock.
                    .accessibilityValue(
                        Duration.seconds(Int(seconds)).formatted(
                            .units(allowed: [.hours, .minutes, .seconds], width: .wide)))
            }
            // Not hidden. Once the stage pins to `.preparing` the bar is
            // indeterminate and has no value left to announce, and this clock is
            // the only remaining evidence that anything is still happening.
            .accessibilityLabel("Elapsed")
        }
    }

    /// Nil where there is genuinely nothing to report, which the bar draws as
    /// indeterminate.
    ///
    /// `.preparing` returns nil rather than 1. FluidAudio weights compilation at
    /// half the operation, and seven of the eight `loadModels` calls happen after
    /// the stage has pinned — so a full bar was shown for minutes of first-time
    /// ANE specialisation on a cold Mac, with a VoiceOver user hearing
    /// "100 percent" and then silence. A bar that has stopped moving is a bar
    /// that should stop claiming a number.
    private func fraction(of stage: ModelDownload.Stage) -> Double? {
        switch stage {
        case .checking, .preparing: return nil
        case .downloading(let fraction): return fraction
        }
    }

    private func caption(for stage: ModelDownload.Stage) -> String {
        switch stage {
        case .checking:
            return "Checking what is already here."
        case .downloading(let fraction):
            return "Downloading, \(Int((fraction * 100).rounded()))%"
        case .preparing:
            return "Downloaded. Preparing them for this Mac."
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Spacing.md) {
            switch download.state {
            case .idle:
                Button("Download now") { download.start() }
                    .buttonStyle(SheetButtonStyle(reduceMotion: reduceMotion))
                    .keyboardShortcut(.defaultAction)
                Button("Not now") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.inkSoft)
                    .keyboardShortcut(.cancelAction)

            case .running:
                // The way out that is not "abandon the download". `start()`
                // captures `self` strongly precisely so dismissing keeps
                // fetching, and until this button existed nothing could produce
                // that state: Cancel held `.cancelAction`, so Escape stopped the
                // download, and a macOS sheet has no other exit. Someone waiting
                // out a 600 MB fetch on hall wifi could not go back and fix their
                // claude login while it ran.
                Button("Keep downloading in the background") { dismiss() }
                    .buttonStyle(SheetButtonStyle(reduceMotion: reduceMotion))
                    .keyboardShortcut(.cancelAction)
                Button("Cancel download") { download.cancel() }
                    .buttonStyle(.plain)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.inkSoft)

            case .done:
                Button("Done") { dismiss() }
                    .buttonStyle(SheetButtonStyle(reduceMotion: reduceMotion))
                    .keyboardShortcut(.defaultAction)

            case .failed:
                Button("Try again") { download.start() }
                    .buttonStyle(SheetButtonStyle(reduceMotion: reduceMotion))
                    .keyboardShortcut(.defaultAction)
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.inkSoft)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - The quantity, drawn as hatching

/// Progress as engraved hatching filling a ruled extent, not as a capsule.
///
/// `HatchSwatch` on its side with a mask over it: same rules (`inkSoft` never
/// `ink`, whole-pixel spacing, coverage under ``Spacing/gutterMaxDensity``).
/// Not shared with it because the swatch encodes speech density into its
/// *spacing* at a fixed width and this encodes a fraction into its *extent* at
/// a fixed spacing — one parameter each, and not the same parameter.
private struct HatchBar: View {

    /// 0…1, or `nil` when the stage genuinely has no figure. An empty extent is
    /// the honest drawing of "nothing has moved yet"; a crawling bar is not.
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One hairline every `xs` is 25% coverage, comfortably under the 60% cap,
    /// and 4pt lands on a whole device pixel at every scale macOS offers — so
    /// unlike the swatch's derived spacing this one needs no snapping.
    private static let step = Spacing.xs

    private var fill: Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        hatching
            // A mask and a transform, per DESIGN.md §6: the hairlines stay
            // where they are engraved and the mask sweeps across them. Animating
            // the band's own width would animate layout, which is banned, and
            // would also drag every hairline sideways.
            .mask {
                Rectangle().scaleEffect(x: fill, anchor: .leading)
            }
            .frame(height: Spacing.xl)
            .overlay {
                Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair)
            }
            .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: fill)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download progress")
            .accessibilityValue(spoken)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// Canvas rather than a stack of `Rectangle`s, for the same reason the
    /// swatch uses one: the hairlines are placed at computed coordinates rather
    /// than laid out and rounded afterwards.
    private var hatching: some View {
        Canvas { context, size in
            var x = Self.step / 2
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: Spacing.hair, height: size.height)),
                    with: .color(Palette.inkSoft))
                x += Self.step
            }
        }
    }

    /// Nil fraction is indeterminate, and it is reached twice: before any bytes
    /// move, and again through the whole CoreML compile. Announcing a percentage
    /// there would be announcing a number that has stopped changing.
    private var spoken: String {
        guard fraction != nil else { return "In progress" }
        return "\(Int((fill * 100).rounded())) percent"
    }
}

// MARK: - Buttons

/// The plate button of the menu bar popover. Duplicated rather than shared
/// because that one is file-private to `MenuBarView`; if a third site wants it,
/// it belongs in `App/Sources/Components/` instead of being copied again.
private struct SheetButtonStyle: ButtonStyle {
    /// Passed in rather than read from the environment. A `ButtonStyle` is not a
    /// `View`, so SwiftUI never installs its `DynamicProperty` wrappers in the
    /// graph and an `@Environment` here reads the default — which is `false`, so
    /// the press fade ran at full duration under Reduce Motion. `SlipButtonStyle`
    /// and `MenuBarView`'s `PlateButtonStyle` already take it as a parameter.
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.uiBold)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Palette.wash)
            .overlay(Rectangle().strokeBorder(Palette.plate, lineWidth: Spacing.plateBorderOuter))
            // 0.55 is the system's one documented opacity floor (the pulse), so
            // press feedback borrows it rather than inventing a second value.
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Motion.tap.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("Not downloaded — light") {
    ModelDownloadView(download: ModelDownload())
        .preferredColorScheme(.light)
}

#Preview("Downloading — dark") {
    ModelDownloadView(
        download: ModelDownload(state: .running(.downloading(0.42)), startedAt: .now.addingTimeInterval(-94)))
        .preferredColorScheme(.dark)
}

#Preview("Cached") {
    ModelDownloadView(download: ModelDownload(state: .done, sizeOnDisk: 643_219_456))
}

#Preview("Failed — captive portal") {
    ModelDownloadView(download: ModelDownload(state: .failed(ModelDownload.Failure(
        reason: "The network answered with a web page instead of the download. That is usually a wifi login that has not been completed yet.",
        detail: "HuggingFace returned HTML instead of JSON for Encoder.mlmodelc/model.mil"))))
}

#Preview("Hatch bar, empty to full") {
    VStack(alignment: .leading, spacing: Spacing.xl) {
        ForEach([nil, 0.08, 0.42, 0.77, 1.0] as [Double?], id: \.self) { fraction in
            HatchBar(fraction: fraction)
        }
    }
    .padding(Spacing.plate)
    .frame(width: 420)
    .background(Palette.sheet)
}
