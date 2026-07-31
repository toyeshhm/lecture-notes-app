import AVFoundation
import Foundation
import Testing
import os

@testable import LectureKit

/// Audio tests avoid the microphone and the 2 GB model download by default: the
/// file writer and the level meter are the parts with logic in them, and both can
/// be driven with synthesised buffers. The two tests that need real hardware or
/// real models are gated on their availability rather than skipped by hand, so
/// they run on a developer machine and stay quiet in CI.

// MARK: - Helpers

/// A function rather than a global: AVAudioFormat is not Sendable, so a global
/// holding one does not compile under strict concurrency.
private func mono16k() throws -> AVAudioFormat {
    try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
}

private func constantBuffer(
    _ value: Float, frames: AVAudioFrameCount, format: AVAudioFormat
) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?.pointee)
    for frame in 0..<Int(frames) { channel[frame] = value }
    return buffer
}

private func scratchURL(_ ext: String = "wav") -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "lecturekit-\(UUID().uuidString).\(ext)")
}

// MARK: - Level meter

@Test func silenceMetersAtZero() throws {
    let format = try mono16k()
    #expect(AudioCapture.level(of: try constantBuffer(0, frames: 512, format: format)) == 0)
}

@Test func fullScaleMetersAtOne() throws {
    let format = try mono16k()
    let level = AudioCapture.level(of: try constantBuffer(1, frames: 512, format: format))
    #expect(abs(level - 1) < 0.001)
}

/// Clamped, not wrapped: a buffer that overshoots full scale must still read as
/// "loud" and not push the meter past its own range.
@Test func aboveFullScaleClampsToOne() throws {
    let format = try mono16k()
    #expect(AudioCapture.level(of: try constantBuffer(4, frames: 512, format: format)) == 1)
}

@Test func halfScaleMetersAtHalf() throws {
    let format = try mono16k()
    let level = AudioCapture.level(of: try constantBuffer(-0.5, frames: 512, format: format))
    #expect(abs(level - 0.5) < 0.001)
}

@Test func emptyBufferMetersAtZero() throws {
    let format = try mono16k()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
    buffer.frameLength = 0  // vDSP over zero elements is undefined; the guard covers it.
    #expect(AudioCapture.level(of: buffer) == 0)
}

// MARK: - File writing

@Test func writesAReadableWavOfTheRightDuration() throws {
    let format = try mono16k()
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try AudioFileWriter(url: url, format: format)
    for _ in 0..<3 {
        writer.write(try constantBuffer(0.25, frames: 16_000, format: format))
    }
    #expect(abs(writer.duration - 3) < 0.001)
    #expect(writer.close() == url)

    // Reading it back is the real assertion: a file with an unflushed header is
    // present on disk and non-empty but unopenable.
    let readBack = try AVAudioFile(forReading: url)
    #expect(readBack.length == 48_000)
    #expect(readBack.fileFormat.sampleRate == 16_000)
}

/// The tap can outlive `stop()` by a buffer. Writing after close must be a no-op
/// rather than a crash, and must not inflate the reported duration.
@Test func writeAfterCloseIsIgnored() throws {
    let format = try mono16k()
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try AudioFileWriter(url: url, format: format)
    writer.write(try constantBuffer(0.5, frames: 1_600, format: format))
    writer.close()
    writer.write(try constantBuffer(0.5, frames: 1_600, format: format))
    #expect(abs(writer.duration - 0.1) < 0.001)
}

/// A format mismatch makes `AVAudioFile.write` raise an ObjC exception that Swift
/// cannot catch, so the writer has to reject the buffer itself.
@Test func mismatchedFormatIsDroppedNotFatal() throws {
    let format = try mono16k()
    let other = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try AudioFileWriter(url: url, format: format)
    writer.write(try constantBuffer(0.5, frames: 1_024, format: other))
    #expect(writer.duration == 0)
    writer.close()
}

@Test func writerFailsOnAnUnwritablePath() throws {
    let format = try mono16k()
    #expect(throws: LectureKitError.self) {
        _ = try AudioFileWriter(
            url: URL(fileURLWithPath: "/nonexistent-directory/out.wav"), format: format
        )
    }
}

// MARK: - Capture

@Test func stoppingWithoutStartingReturnsNil() async {
    let capture = AudioCapture()
    #expect(await capture.stop() == nil)
    #expect(await capture.capturedDuration == 0)
}

/// The only test that touches real hardware. Gated on permission already being
/// granted, because an ungranted run would block on a system dialog forever.
@Test(
    .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
    .timeLimit(.minutes(1))
)
func capturesFromTheMicrophone() async throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let buffers = OSAllocatedUnfairLock(initialState: 0)
    let capture = AudioCapture()
    try await capture.start(writingTo: url) { _ in
        buffers.withLock { $0 += 1 }
    }
    try await Task.sleep(for: .milliseconds(600))
    let finished = await capture.stop()

    #expect(finished == url)
    #expect(buffers.withLock { $0 } > 0, "the tee must reach the callback")
    #expect(await capture.capturedDuration > 0.1, "and the file, for roughly the same audio")
    let readBack = try AVAudioFile(forReading: url)
    #expect(readBack.length > 0)
}

// MARK: - Batch transcription

/// Runs only when the models are already cached — downloading them is gigabytes,
/// which no test should decide to do on its own. `say` supplies real speech,
/// since a synthesised tone would legitimately transcribe to nothing.
@Test(.enabled(if: Transcriber.modelsAreCached), .timeLimit(.minutes(2)))
func transcribesAShortSpokenFile() async throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = [
        "--data-format=LEI16@22050", "--file-format=WAVE", "-o", url.path,
        "the derivative of a product is the chain rule",
    ]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)

    let text = try await Transcriber.transcribeFile(url)
    #expect(!text.isEmpty)
}
