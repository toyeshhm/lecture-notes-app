import Foundation
import Testing

@testable import LectureKit

/// These hit the real CLI. Mocking the subprocess would test the mock: the two
/// things that actually break — the flag stack and the environment — only fail
/// against the real binary. Machines without it skip rather than fail.
@Suite struct ClaudeRunnerTests {
    @Test func locateFindsAnExecutable() {
        guard let path = ClaudeRunner.locate() else { return }
        #expect(FileManager.default.isExecutableFile(atPath: path.path))
    }

    @Test(.timeLimit(.minutes(2)))
    func runReturnsTheModelsReply() async throws {
        guard ClaudeRunner.locate() != nil else { return }

        let text = try await ClaudeRunner().run(
            prompt: "Reply with exactly: OK",
            system: "You reply with exactly what you are asked for, nothing else.",
            model: "sonnet"
        )
        #expect(text == "OK")
    }

    @Test func environmentCarriesTheFourVariablesTheCLINeeds() {
        let env = ClaudeRunner.environment(for: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))

        #expect(env["HOME"] == NSHomeDirectory())
        #expect(env["USER"] == NSUserName())
        #expect(env["LOGNAME"] == NSUserName())
        // The binary's own directory has to lead, plus the system defaults.
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }
}
