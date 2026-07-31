import Foundation

/// Reads the Python CLI's `config.toml` so an existing setup carries over.
///
/// The app and the CLI write into the same vaults from the same machine, so a
/// first run that asked for the vault path again would be asking a question the
/// answer to which is already on disk — and a first run that imported *some* of
/// the config would be worse than one that imported none: a settings screen
/// showing the right vault and no mirrors reads as correctly configured, and the
/// second copy of every lecture stops being written without anything saying so.
///
/// This is a subset reader, not a TOML implementation. It covers exactly what the
/// CLI writes: top-level scalars, `[[mirrors]]` array-of-tables, one inline table
/// for a mirror's extra frontmatter, `#` comments, and the three scalar types
/// those keys use. Anything else is skipped rather than guessed at, because a
/// misread setting writes lecture notes to the wrong place.
public enum ConfigImport {

    public static let defaultPath = URL.homeDirectory
        .appending(path: ".config/lecture-notes/config.toml")

    /// The CLI's settings, or nil when there is no config to import.
    public static func settings(at path: URL = defaultPath) -> Settings? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return settings(toml: text)
    }

    /// - Note: `vault` is the one required key. Without it there is nothing to
    ///   import — a config naming models but no vault would produce a Settings
    ///   pointing at the home directory, which is worse than no import at all.
    public static func settings(toml: String) -> Settings? {
        let document = parse(toml)
        guard let vault = document.root["vault"]?.string else { return nil }

        let defaults = Settings(vault: URL(fileURLWithPath: vault))
        return Settings(
            vault: URL(fileURLWithPath: vault),
            coursesSubdir: document.root["courses_subdir"]?.string ?? defaults.coursesSubdir,
            lecturesSubdir: document.root["lectures_subdir"]?.string ?? defaults.lecturesSubdir,
            liveInterval: document.root["live_interval_s"]?.number ?? defaults.liveInterval,
            minWordsPerPass: document.root["min_words_per_pass"]?.number.map(Int.init)
                ?? defaults.minWordsPerPass,
            liveModel: document.root["live_model"]?.string ?? defaults.liveModel,
            finalModel: document.root["final_model"]?.string ?? defaults.finalModel,
            detectModel: document.root["detect_model"]?.string ?? defaults.detectModel,
            keepTranscript: document.root["keep_transcript"]?.boolean ?? defaults.keepTranscript,
            keepAudio: document.root["keep_audio"]?.boolean ?? defaults.keepAudio,
            mirrors: document.mirrors.compactMap(mirror),
            claudePath: document.root["claude_path"]?.string.map { URL(fileURLWithPath: $0) },
            pinnedCourse: document.root["course"]?.string)
    }

    /// A mirror without a vault is not a mirror. Dropping it is right: the
    /// alternative is a target pointing at the home directory, which would
    /// scatter lecture notes across it.
    private static func mirror(_ table: [String: Value]) -> MirrorTarget? {
        guard let vault = table["vault"]?.string else { return nil }
        return MirrorTarget(
            vault: URL(fileURLWithPath: vault),
            coursesSubdir: table["courses_subdir"]?.string ?? "Courses",
            lecturesSubdir: table["lectures_subdir"]?.string ?? "Lectures",
            // Defaults to false, matching the CLI: a mirror is a browsing copy,
            // and the primary vault keeps the full transcript.
            keepTranscript: table["keep_transcript"]?.boolean ?? false,
            frontmatter: table["frontmatter"]?.table ?? [:])
    }

    // MARK: - The subset reader

    enum Value: Equatable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case table([String: String])

        var string: String? { if case .string(let value) = self { value } else { nil } }
        var number: Double? { if case .number(let value) = self { value } else { nil } }
        var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }
        var table: [String: String]? { if case .table(let value) = self { value } else { nil } }
    }

    struct Document: Equatable {
        var root: [String: Value] = [:]
        var mirrors: [[String: Value]] = []
    }

    static func parse(_ toml: String) -> Document {
        var document = Document()
        // Nil while in the root table; an index into `mirrors` once a
        // `[[mirrors]]` header has been seen. Any other header switches to a
        // section this reader does not model, and its keys are dropped rather
        // than being folded into the root — where `vault` under some future
        // `[whisper]` section would silently become *the* vault.
        var target: Int??

        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = strippingComment(rawLine)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                if line == "[[mirrors]]" {
                    document.mirrors.append([:])
                    target = .some(document.mirrors.count - 1)
                } else {
                    target = .some(nil)   // a section we do not model
                }
                continue
            }

            guard let (key, value) = keyValue(line) else { continue }
            switch target {
            case .none:
                document.root[key] = value
            case .some(.some(let index)):
                document.mirrors[index][key] = value
            case .some(.none):
                continue
            }
        }
        return document
    }

    /// Strips a trailing `#` comment, but not one inside a quoted string — every
    /// value here is a filesystem path, and `~/Notes/#archive` is a legal one.
    private static func strippingComment(_ line: Substring) -> Substring {
        var inQuotes = false
        for index in line.indices {
            switch line[index] {
            case "\"": inQuotes.toggle()
            case "#" where !inQuotes: return line[..<index].trimmed
            default: continue
            }
        }
        return line.trimmed
    }

    private static func keyValue(_ line: Substring) -> (String, Value)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equals].trimmed)
        guard !key.isEmpty else { return nil }
        return value(line[line.index(after: equals)...].trimmed).map { (key, $0) }
    }

    private static func value(_ raw: Substring) -> Value? {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if raw.hasPrefix("{"), raw.hasSuffix("}") {
            return .table(inlineTable(raw.dropFirst().dropLast()))
        }
        if let number = Double(raw) { return .number(number) }
        return nil
    }

    /// `{ generated_by = "Toyo", source = "app" }`. Split on commas, which is
    /// safe here because every value in this position is an identifier or a
    /// short quoted word — the CLI writes frontmatter keys, not prose.
    private static func inlineTable(_ body: Substring) -> [String: String] {
        var table: [String: String] = [:]
        for pair in body.split(separator: ",") {
            guard let (key, value) = keyValue(pair.trimmed) else { continue }
            switch value {
            case .string(let text): table[key] = text
            case .number(let number): table[key] = String(number)
            case .boolean(let flag): table[key] = String(flag)
            case .table: continue
            }
        }
        return table
    }
}

extension Substring {
    fileprivate var trimmed: Substring {
        var result = self
        while let first = result.first, first.isWhitespace { result = result.dropFirst() }
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }
}
