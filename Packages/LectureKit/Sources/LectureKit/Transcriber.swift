// See AudioCapture.swift: buffers are handed straight on to FluidAudio, which
// imports AVFoundation the same way.
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Streaming speech-to-text, and a batch pass for the kept transcript.
///
/// Replaces parakeet-mlx. The Python had to hold back the last twelve words of
/// every streaming result by hand, because Parakeet rewrites text still inside
/// its attention window ("Yeah." becomes "Today") and emitting it immediately
/// baked provisional wording into the notes. FluidAudio marks that distinction
/// itself, so `confirmedText` simply drops volatile updates — the word-counting
/// hold-back is gone, along with the off-by-one bugs it invited.
public actor Transcriber {
    /// v3 is the multilingual Parakeet model; the sliding-window manager resamples
    /// whatever we feed it to 16 kHz internally, so the capture format is free.
    private static let version: AsrModelVersion = .v3

    private let manager = SlidingWindowAsrManager()
    private var pump: Task<Void, Never>?
    private var intake: Task<Void, Never>?

    /// Confirmed transcript segments, in order. Never volatile text.
    public nonisolated let confirmedText: AsyncStream<String>
    private nonisolated let confirmed: AsyncStream<String>.Continuation

    /// Captured audio on its way to the decoder, in the order it was captured.
    ///
    /// Buffers arrive on the realtime audio thread, which cannot await. Wrapping
    /// each one in its own `Task` to reach this actor would let the scheduler
    /// deliver them in any order — the decoder would be fed shuffled audio and
    /// the transcript would be nonsense. One stream drained by one task cannot
    /// reorder, so `feed` stays synchronous and callable from the tap.
    private let audioIn: AsyncStream<AVAudioPCMBuffer>
    /// The continuation is Sendable even though the buffers are not, which is the
    /// whole point: the tap can hand one over without hopping anywhere.
    private nonisolated let audio: AsyncStream<AVAudioPCMBuffer>.Continuation

    public init() {
        // Unbounded, unlike the level stream: a dropped segment is a hole in the
        // notes, so a slow consumer must be made to wait rather than lose text.
        (confirmedText, confirmed) = AsyncStream.makeStream()
        (audioIn, audio) = AsyncStream.makeStream()
    }

    /// True when the models are already on disk, so the caller can warn about a
    /// multi-gigabyte download before `loadModels()` blocks on one.
    public static var modelsAreCached: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Downloads on first use.
    public func loadModels() async throws {
        do {
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            try await manager.loadModels(models)
        } catch {
            // No transcript can ever arrive now, and `finish()` will not be
            // reached, so release anyone already awaiting `confirmedText`.
            confirmed.finish()
            throw LectureKitError.modelsUnavailable(error.localizedDescription)
        }
    }

    public func start() async throws {
        // One session per instance, like AudioCapture. A second `start` would put
        // a second iterator on `audioIn` — an AsyncStream permits exactly one —
        // and drop the first pump's subscription on the floor.
        guard pump == nil, intake == nil else {
            throw LectureKitError.captureFailed("already transcribing")
        }
        // Subscribe before streaming starts: `transcriptionUpdates` installs the
        // continuation on access, and anything decoded before that is dropped.
        // The stream buffers, so the pump can be attached after the engine runs.
        let updates = await manager.transcriptionUpdates
        do {
            try await manager.startStreaming(source: .microphone)
        } catch {
            // Started nothing, so nothing will finish these: do it here rather
            // than leave a pump task and a suspended consumer behind.
            confirmed.finish()
            throw error
        }

        let confirmed = self.confirmed
        pump = Task {
            for await update in updates where update.isConfirmed {
                confirmed.yield(update.text)
            }
        }

        intake = Task {
            for await buffer in self.audioIn {
                await self.manager.streamAudio(buffer)
            }
        }
    }

    /// Hand a captured buffer to the decoder.
    ///
    /// Synchronous and nonisolated so it can be called straight from the capture
    /// tap: see `audioIn` for why ordering rules out an `async` method here.
    public nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        audio.yield(buffer)
    }

    /// Flush the decoder and return the streamed transcript.
    public func finish() async throws -> String {
        // Close the intake and let it drain first. A buffer still queued when
        // `manager.finish()` runs is audio dropped off the end of the lecture.
        audio.finish()
        await intake?.value
        intake = nil
        defer {
            pump?.cancel()
            pump = nil
            confirmed.finish()
        }
        let text = try await manager.finish()
        // `finish()` leaves the manager's update stream open; only `cancel()`
        // closes it. Without this its continuation outlives the session.
        await manager.cancel()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe a finished recording in one pass.
    ///
    /// Used for the transcript kept alongside the notes: a batch decode sees the
    /// whole file, so it is more accurate than the streaming text, which had to
    /// commit to each window with only a few seconds of right context.
    public static func transcribeFile(_ url: URL) async throws -> String {
        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: version)
        } catch {
            throw LectureKitError.modelsUnavailable(error.localizedDescription)
        }
        let manager = AsrManager()
        try await manager.loadModels(models)
        // A fresh decoder state per file; carrying one over would leak the
        // previous lecture's context into the first seconds of this one.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
