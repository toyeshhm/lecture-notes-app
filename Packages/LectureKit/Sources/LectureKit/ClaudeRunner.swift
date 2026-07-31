import Foundation

/// Headless calls to the `claude` CLI.
///
/// The CLI is used rather than the HTTP API because it authenticates with the
/// user's existing subscription (OAuth) — no API key to store, no per-token bill.
public struct ClaudeRunner: Sendable {
    /// Resolved once at init: locating the binary hits the filesystem, and every
    /// live pass would otherwise repeat that search.
    public let claudePath: URL?

    /// `nil` searches the known install locations.
    public init(claudePath: URL? = nil) {
        self.claudePath = claudePath ?? Self.locate()
    }

    /// Where the CLI installs itself, in the order the installers prefer.
    ///
    /// A GUI app has no shell `PATH` to search, so the list is hard-coded.
    public static func locate() -> URL? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The environment the spawned process needs to authenticate.
    ///
    /// A GUI app inherits almost no environment, and the CLI fails in ways that
    /// look like anything but a missing variable. Measured:
    ///
    ///     HOME only                    -> fails with "Not logged in - Please run /login"
    ///     HOME + PATH + USER + LOGNAME -> works
    ///
    /// All four are therefore mandatory. Without them every note silently fails
    /// at the last step, after the whole lecture has already been recorded.
    static func environment(for binary: URL) -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            // The binary's own directory is included because the CLI shells out
            // to siblings shipped beside it.
            "PATH": binary.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
        ]
    }

    /// Call `claude -p` headlessly and return the text result.
    public func run(
        prompt: String,
        system: String,
        model: String,
        timeout: TimeInterval = 240
    ) async throws -> String {
        guard let binary = claudePath else { throw LectureKitError.claudeNotFound }

        let process = Process()
        process.executableURL = binary
        // A plain `claude -p` loads CLAUDE.md, every plugin and every MCP server
        // — measured at 41,811 tokens and 35s for a four-token reply. This stack
        // makes the identical call 187 tokens and 2.4s while keeping subscription
        // auth. Do NOT add --bare: it forces ANTHROPIC_API_KEY and bypasses the
        // subscription entirely.
        process.arguments = [
            "-p", prompt,
            "--system-prompt", system,
            "--model", model,
            "--setting-sources", "",
            "--strict-mcp-config",
            "--tools", "",
            "--output-format", "json",
        ]
        process.environment = Self.environment(for: binary)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently with the wait below. A note easily
        // exceeds the 64 KB pipe buffer, and a full buffer blocks the child
        // forever if nothing is reading.
        let stdout = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let stderr = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        // Both readers block until every write end of their pipe is closed, and a
        // detached task is not cancelled with its parent — so every exit from here
        // has to make that happen, or the task sits on a pool thread for good.
        func killAndDrain() async {
            process.terminate()
            _ = await stdout.value
            _ = await stderr.value
        }

        do {
            try process.run()
        } catch {
            // The child never existed, so it will never close the write ends we
            // are still holding. Close them or the readers never see EOF.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = await stdout.value
            _ = await stderr.value
            throw LectureKitError.claudeFailed("could not launch \(binary.path): \(error)")
        }

        // ponytail: polling beats a termination handler here — no continuation to
        // race against a process that exits before the handler is installed, and
        // the timeout falls out of the same loop. 50 ms against a 2.4s call.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                await killAndDrain()
                throw LectureKitError.claudeFailed(
                    "claude timed out after \(Int(timeout))s")
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                // Cancellation: kill the child rather than orphan a `claude`
                // process that nothing is left to wait on or reap.
                await killAndDrain()
                throw error
            }
        }

        let outText = String(decoding: await stdout.value, as: UTF8.self)
        let errText = String(decoding: await stderr.value, as: UTF8.self)

        // Checked before anything else: the logged-out message arrives sometimes
        // as the JSON result, sometimes on stderr with a non-zero exit, and the
        // caller needs the same actionable error either way.
        if outText.contains("Not logged in") || errText.contains("Not logged in") {
            throw LectureKitError.claudeNotLoggedIn
        }

        guard process.terminationStatus == 0 else {
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)
            throw LectureKitError.claudeFailed(
                "claude exited \(process.terminationStatus): \(detail)")
        }

        struct Payload: Decodable {
            let isError: Bool?
            let result: String?

            enum CodingKeys: String, CodingKey {
                case isError = "is_error"
                case result
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(outText.utf8))
        else {
            throw LectureKitError.claudeFailed("claude returned non-JSON: \(outText.prefix(300))")
        }
        if payload.isError == true {
            throw LectureKitError.claudeFailed(
                "claude reported an error: \(payload.result ?? "")")
        }
        guard let result = payload.result else {
            throw LectureKitError.claudeFailed(
                "claude returned no result field: \(outText.prefix(300))")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
