import Accelerate
// AVAudioPCMBuffer is not Sendable, and never will be — it is a reference type
// handed to us by a realtime callback. FluidAudio imports AVFoundation the same
// way for the same reason, and buffers only ever travel forwards here: the tap
// hands each one on and never touches it again.
@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Microphone capture: one tap, two consumers.
///
/// The Python version ran ffmpeg writing to a file while a separate reader fed
/// the transcriber, because a pipe applies backpressure — streaming decode runs
/// slower than realtime, so the backlog grows and the end of the lecture is lost
/// on stop. The same guarantee holds here by teeing every tap buffer to the file
/// and to the caller's callback independently: neither consumer can stall the
/// other, and the file remains the authoritative record when transcription lags.
///
/// One capture per instance. `stop()` ends `levelStream`, so a meter's `for await`
/// loop terminates rather than hanging on a finished session.
public actor AudioCapture {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var running = false

    /// RMS of each captured buffer, 0 (silence) to 1 (full scale).
    public nonisolated let levelStream: AsyncStream<Float>

    /// A meter only ever draws the newest value, so an unread stream must not
    /// accumulate a lecture's worth of levels.
    private nonisolated let levels: AsyncStream<Float>.Continuation

    public init() {
        (levelStream, levels) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Seconds written to disk — the length of the recording, not of the
    /// transcript, which trails it. Still readable after `stop()`, because that
    /// is when the caller wants it for the note.
    public var capturedDuration: TimeInterval { writer?.duration ?? 0 }

    /// Begin capturing to `url`, teeing every buffer to `onBuffer`.
    ///
    /// `async` only because permission cannot be requested from a synchronous
    /// actor method; callers already await, as every actor method is async across
    /// the boundary.
    public func start(
        writingTo url: URL,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        guard !running else {
            throw LectureKitError.captureFailed("already recording")
        }
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw LectureKitError.microphoneDenied
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A machine with no usable input reports 0 Hz; installing a tap with
            // that format traps inside CoreAudio rather than returning an error.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw LectureKitError.captureFailed("no audio input device")
            }

            let writer = try AudioFileWriter(url: url, format: format)
            let levels = self.levels
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                // Disk first: a slow or throwing transcriber must not cost us the
                // recording, which is the only irreplaceable half of this.
                writer.write(buffer)
                onBuffer(buffer)
                levels.yield(AudioCapture.level(of: buffer))
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                writer.close()
                throw LectureKitError.captureFailed(error.localizedDescription)
            }
            self.writer = writer
            running = true
        } catch {
            // Nothing will ever be captured, so release the meter. An AsyncStream
            // whose continuation is merely dropped never terminates: a `for await`
            // on `levelStream` started alongside this call would stay suspended
            // for the lifetime of the app.
            levels.finish()
            throw error
        }
    }

    /// Stop capturing and close the file. Nil if nothing was being recorded.
    public func stop() -> URL? {
        // Before the guard, and unconditionally: the guard is also the path taken
        // after a `start()` that threw, and a meter already iterating `levelStream`
        // by then would otherwise never be released.
        levels.finish()
        guard running, let writer else { return nil }
        // Tap first: the engine can deliver one more buffer while stopping, and a
        // late write to a closed file must be dropped by the writer, not reach
        // AVAudioFile.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        return writer.close()
    }

    /// RMS of the first channel, clamped to 0...1.
    ///
    /// RMS rather than peak: a meter driven by peaks sits pinned at the top on any
    /// room noise and tells the user nothing about whether speech is arriving.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else {
            return 0
        }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        return min(1, rms)
    }
}

/// The file half of the tee, guarded by a lock.
///
/// Tap buffers arrive on a realtime audio thread while `stop()` arrives on the
/// actor, and both touch the file. Hopping to the actor from the tap would make
/// every write async — audio would be reordered and dropped under load — so the
/// file lives behind a lock instead of in actor state.
final class AudioFileWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: "LectureKit", category: "audio")

    let url: URL
    private let lock = NSLock()
    private let sampleRate: Double
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0

    /// Writes 16-bit PCM whatever the input format, so the result is a WAV any
    /// tool can read, while keeping the *processing* format identical to the
    /// tap's — `AVAudioFile.write` raises an ObjC exception, uncatchable from
    /// Swift, when the buffer format differs from the file's processing format.
    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        self.sampleRate = format.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
        } catch {
            throw LectureKitError.captureFailed(error.localizedDescription)
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        guard buffer.format == file.processingFormat else {
            Self.log.error("dropping buffer: format \(buffer.format) is not the file's")
            return
        }
        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A full disk must not tear down transcription mid-lecture. The
            // shortfall is visible in `duration`, which stops advancing.
            Self.log.error("audio write failed: \(error.localizedDescription)")
        }
    }

    /// Close the file and return its URL. Idempotent.
    @discardableResult
    func close() -> URL {
        lock.lock()
        defer { lock.unlock() }
        file = nil  // AVAudioFile flushes the header and closes on deinit.
        return url
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }
}
