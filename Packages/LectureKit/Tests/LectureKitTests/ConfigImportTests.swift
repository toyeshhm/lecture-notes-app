import Foundation
import Testing

@testable import LectureKit

/// A real config the CLI wrote, structurally verbatim.
///
/// Copied rather than paraphrased: the point of the import is to read *this*, and
/// a fixture tidied into the shape the parser expects tests the parser against
/// itself. Every comment, blank line and key order is as the CLI emits it. The
/// commented-out block matters as much as the live keys — it is how the CLI ships
/// its defaults, and a reader that treats `# live_model = "sonnet"` as a setting
/// would silently pin the model.
///
/// Only the two vault paths are substituted, and they are substituted for
/// something with the same shape: a deep path, under a cloud-sync folder, with a
/// space in the last component. Those are the properties that could break a
/// parser. The originals named a real person's private vaults and this file is
/// public.
private let realConfig = """
    # lecture-notes configuration
    # Every key here can be overridden by a LECTURE_NOTES_<KEY> env var
    # or a command-line flag.

    vault = "/Users/example/Library/CloudStorage/Dropbox/Apps/remotely-save/Personal"
    courses_subdir = "00 - Courses"
    lectures_subdir = "Lectures"

    # live_interval_s = 180.0
    # live_model = "sonnet"
    # final_model = "opus"
    # audio_device = "1"

    # Second copy into Toyo Brain (the agent-generated vault). Written from the
    # same source in one pass, never synced from the Personal copy. Transcript is
    # omitted here -- Personal keeps the full one.
    [[mirrors]]
    vault = "/Users/example/Library/CloudStorage/Dropbox/Apps/remotely-save/Second Brain"
    courses_subdir = "02 Areas/Courses"
    lectures_subdir = "Lectures"
    keep_transcript = false
    frontmatter = { generated_by = "Toyo" }
    """

@Test("the real config imports with its mirror intact")
func realConfigRoundTrips() throws {
    let settings = try #require(ConfigImport.settings(toml: realConfig))

    #expect(settings.vault.lastPathComponent == "Personal")
    #expect(settings.coursesSubdir == "00 - Courses")
    #expect(settings.lecturesSubdir == "Lectures")

    // The whole reason this file exists. Importing the vault and dropping the
    // mirror produces a settings screen that looks correctly configured while
    // the second copy of every lecture silently stops being written.
    let mirror = try #require(settings.mirrors.first)
    #expect(settings.mirrors.count == 1)
    #expect(mirror.vault.lastPathComponent == "Second Brain")
    #expect(mirror.coursesSubdir == "02 Areas/Courses")
    #expect(mirror.keepTranscript == false)
    #expect(mirror.frontmatter == ["generated_by": "Toyo"])
}

@Test("commented-out defaults are comments, not settings")
func commentedKeysAreNotImported() throws {
    let settings = try #require(ConfigImport.settings(toml: realConfig))
    let defaults = Settings(vault: settings.vault)

    #expect(settings.liveModel == defaults.liveModel)
    #expect(settings.finalModel == defaults.finalModel)
    #expect(settings.liveInterval == defaults.liveInterval)
}

@Test("live keys override the defaults")
func liveKeysAreImported() throws {
    let settings = try #require(ConfigImport.settings(toml: """
        vault = "/tmp/v"
        live_interval_s = 240.0
        live_model = "haiku"
        final_model = "opus"
        keep_audio = true
        min_words_per_pass = 60
        course = "CS 314H"
        """))

    #expect(settings.liveInterval == 240)
    #expect(settings.liveModel == "haiku")
    #expect(settings.finalModel == "opus")
    #expect(settings.keepAudio)
    #expect(settings.minWordsPerPass == 60)
    #expect(settings.pinnedCourse == "CS 314H")
}

@Test("a trailing comment is stripped, but a # inside a path is not")
func commentStrippingRespectsQuotes() throws {
    let settings = try #require(ConfigImport.settings(toml: """
        vault = "/tmp/#archive"   # where it lives
        lectures_subdir = "Talks" # not Lectures
        """))

    // `normalised` marks a vault as a directory, hence the trailing slash.
    #expect(settings.vault.path(percentEncoded: false) == "/tmp/#archive/")
    #expect(settings.lecturesSubdir == "Talks")
}

@Test("several mirrors each keep their own settings")
func multipleMirrors() throws {
    let settings = try #require(ConfigImport.settings(toml: """
        vault = "/tmp/primary"

        [[mirrors]]
        vault = "/tmp/one"
        keep_transcript = true

        [[mirrors]]
        vault = "/tmp/two"
        courses_subdir = "Areas/Courses"
        frontmatter = { generated_by = "Toyo", source = "app" }
        """))

    #expect(settings.mirrors.count == 2)
    #expect(settings.mirrors[0].keepTranscript)
    #expect(settings.mirrors[1].keepTranscript == false)
    #expect(settings.mirrors[1].coursesSubdir == "Areas/Courses")
    #expect(settings.mirrors[1].frontmatter == ["generated_by": "Toyo", "source": "app"])
}

@Test("a section this reader does not model cannot leak into the root")
func unknownSectionsAreSkipped() throws {
    // The failure this guards: a future `[whisper]` block with its own `vault`
    // key folding into the root and becoming *the* vault, which would file every
    // lecture somewhere the user never chose.
    let settings = try #require(ConfigImport.settings(toml: """
        vault = "/tmp/correct"

        [whisper]
        vault = "/tmp/wrong"
        model = "large-v3"
        """))

    #expect(settings.vault.path(percentEncoded: false) == "/tmp/correct/")
}

@Test("a mirror with no vault is dropped rather than pointed at home")
func mirrorWithoutVaultIsDropped() throws {
    let settings = try #require(ConfigImport.settings(toml: """
        vault = "/tmp/primary"

        [[mirrors]]
        courses_subdir = "Courses"
        """))

    #expect(settings.mirrors.isEmpty)
}

@Test("no vault means there is nothing to import")
func configWithoutVaultImportsNothing() {
    #expect(ConfigImport.settings(toml: "live_model = \"haiku\"") == nil)
    #expect(ConfigImport.settings(toml: "") == nil)
}

@Test("a missing config file is not an error")
func missingFileImportsNothing() {
    let absent = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).toml")
    #expect(ConfigImport.settings(at: absent) == nil)
}
