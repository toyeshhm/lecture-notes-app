import AppKit
import Foundation

/// Proves the course-to-plate assignment is stable, spread, and survives a
/// broken `Assets/Plates`.
///
/// Compiled against `App/Sources/PlateAssignment.swift` itself rather than a
/// copy of its arithmetic, so a change to the hash, the offset basis, the
/// normalisation or the manifest ordering fails here. `Bundle.main` for a plain
/// executable is the directory holding it, so a `Plates` symlink beside the
/// binary is a real bundle lookup — no stubbing, and the failure modes are
/// produced by actually breaking files on disk.
///
/// Usage:
///   swiftc -swift-version 6 App/Sources/PlateAssignment.swift \
///     Tools/PlateAssignmentTest/main.swift -o /tmp/plate-test
///   ln -sfn "$PWD/Assets/Plates" /tmp/Plates && /tmp/plate-test

// MARK: - Harness

var failures: [String] = []

@MainActor
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition {
        print("  ok   \(message())")
    } else {
        print("  FAIL \(message())")
        failures.append(message())
    }
}

/// Courses spanning the shapes a roster actually holds: letter-suffixed codes,
/// single-letter departments, and codes differing only in their last character.
let courses = [
    "CS 314H", "MATH 340", "PHY 303", "CHEM 101", "BIO 311C", "HIST 315K",
    "ECON 420K", "PSY 301", "LIN 306", "M 408D", "EE 306", "GOV 310L",
]

@MainActor func mapping() -> [(String, String)] {
    courses.map { ($0, PlateAssignment.plate(for: $0)?.species ?? "nil") }
}

// MARK: - Child modes
//
// The parent re-runs this binary to get a genuinely separate process, and runs
// copies of it beside deliberately broken plate directories.

@MainActor func report() {
    for (course, species) in mapping() { print("\(course)\t\(species)") }
}

if CommandLine.arguments.contains("--report") {
    report()
    exit(0)
}

// MARK: - 1. Stability against recorded values
//
// These were recorded by an earlier process. Swift's `Hasher` is seeded per
// process, so an assignment built on it would fail this on the second run —
// which is the whole reason PlateAssignment carries its own FNV-1a.

print("1. assignment matches values recorded by an earlier process")

let golden = [
    "CS 314H": "Viola tricolor",
    "MATH 340": "Fraxinus ornus",
    "PHY 303": "Melaleuca leucadendra",
    "CHEM 101": "Scopolia carniolica",
    "BIO 311C": "Smilax aristolochiifolia",
    "HIST 315K": "Smilax aristolochiifolia",
    "ECON 420K": "Manihot glaziovii",
    "PSY 301": "Elettaria cardamomum",
    "LIN 306": "Elettaria cardamomum",
    "M 408D": "Fraxinus ornus",
    "EE 306": "Pimenta dioica",
    "GOV 310L": "Cinchona pubescens",
]

for (course, species) in mapping() {
    check(golden[course] == species, "\(course) -> \(species)")
}

// MARK: - 2. Stability across separate invocations
//
// Recorded values only prove stability if they were recorded correctly. This
// spawns the same binary again and compares, so the claim holds even if the
// table above were wrong.

print("\n2. a second process assigns the same plates")

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--report"]
let pipe = Pipe()
child.standardOutput = pipe
try child.run()
let childOutput = String(
    data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
child.waitUntilExit()

let ownOutput = mapping()
    .map { "\($0.0)\t\($0.1)\n" }.joined()
check(child.terminationStatus == 0, "child exited cleanly")
check(childOutput == ownOutput, "child mapping is byte-identical to this process's")

// MARK: - 3. Normalisation
//
// Case and spacing are how a code gets typed, not what it is.

print("\n3. case and spacing do not change the plate")

let spellings = ["CS 314H", "cs314h", "CS  314H", "  cs 314 h  ", "Cs314H"]
let species = spellings.map { PlateAssignment.plate(for: $0)?.species ?? "nil" }
check(Set(species).count == 1, "\(spellings.count) spellings of CS 314H -> \(species[0])")
check(
    PlateAssignment.plate(for: "   ") == nil,
    "a code that normalises to nothing has no plate")

// MARK: - 4. Distribution
//
// Not degenerate: every plate is reachable and no plate is a magnet. Ordinary
// department codes rather than random strings, because the assignment only has
// to be spread over the inputs it actually sees.

print("\n4. plates are spread across the collection")

let departments = [
    "CS", "MATH", "PHY", "CHEM", "BIO", "HIST", "ECON", "PSY", "ENG", "ART",
    "MUS", "PHL", "GOV", "ANT", "SOC", "STA", "EE", "ME", "LIN", "GEO",
]
let numbers = [
    "101", "102", "201", "210", "303", "314H", "311", "321", "340", "350",
    "401", "410", "420", "429", "439",
]
let sample = departments.flatMap { department in numbers.map { "\(department) \($0)" } }

var histogram: [String: Int] = [:]
for course in sample {
    let plate = PlateAssignment.plate(for: course)
    guard let plate else { continue }
    histogram[plate.species, default: 0] += 1
}

// The manifest is the source of truth for how many plates exist; hard-coding a
// count here would just go stale the next time one is added.
let plateCount = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: "Plates/plates.json")))
let manifestCount = ((plateCount as? [String: Any])?["plates"] as? [Any])?.count ?? 0

check(manifestCount > 0, "manifest lists \(manifestCount) plates")
check(
    histogram.count == manifestCount,
    "all \(manifestCount) plates used by \(sample.count) courses (saw \(histogram.count))")

let expected = Double(sample.count) / Double(max(manifestCount, 1))
let heaviest = histogram.values.max() ?? 0
check(
    Double(heaviest) < expected * 2.5,
    "heaviest plate takes \(heaviest) of \(sample.count), under 2.5x the even share "
        + "of \(String(format: "%.1f", expected))")

// MARK: - 5. Degradation
//
// A half-synced checkout is the state the type was written for. Reproduced by
// copying the binary next to a plate directory that is broken in each of the
// ways a checkout breaks it, and checking the child neither crashes nor takes
// the rest of the collection down with it.

print("\n5. a broken plate directory degrades instead of crashing")

let assets = URL(fileURLWithPath: "Plates").resolvingSymlinksInPath()
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "plate-degradation-\(ProcessInfo.processInfo.processIdentifier)")

/// Runs this binary in a directory whose `Plates` has been broken by `damage`,
/// and returns what it printed. `nil` means it crashed.
@MainActor
func runBroken(_ name: String, damage: (URL) throws -> Void) throws -> String? {
    let directory = scratch.appending(path: name)
    let plates = directory.appending(path: "Plates")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: CommandLine.arguments[0]),
        to: directory.appending(path: "test"))
    try FileManager.default.copyItem(at: assets, to: plates)
    try damage(plates)

    let process = Process()
    process.executableURL = directory.appending(path: "test")
    process.arguments = ["--report"]
    process.currentDirectoryURL = directory
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    return process.terminationStatus == 0 ? text : nil
}

defer { try? FileManager.default.removeItem(at: scratch) }

// CS 314H's plate, per the recorded table above. Breaking it must take out that
// one row and nothing else.
let victim = "viola-tricolor"

let cases: [(String, (URL) throws -> Void, Bool)] = [
    ("no manifest", { try FileManager.default.removeItem(at: $0.appending(path: "plates.json")) }, false),
    ("unparseable manifest", { try "{ not json".write(to: $0.appending(path: "plates.json"), atomically: true, encoding: .utf8) }, false),
    ("missing image", { try FileManager.default.removeItem(at: $0.appending(path: "\(victim).jpg")) }, true),
    ("truncated image", { try Data("half a jpeg".utf8).write(to: $0.appending(path: "\(victim).jpg")) }, true),
]

for (name, damage, othersSurvive) in cases {
    guard let output = try runBroken(name.replacingOccurrences(of: " ", with: "-"), damage: damage)
    else {
        check(false, "\(name): crashed")
        continue
    }
    let lines = output.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    let assigned = lines.filter { $0.count == 2 && $0[1] != "nil" }

    check(lines.count == courses.count, "\(name): every course still answered")
    check(
        lines.first { $0.first == "CS 314H" }?.last == "nil",
        "\(name): the affected course has no plate rather than a crash")
    if othersSurvive {
        check(!assigned.isEmpty, "\(name): \(assigned.count) other courses keep their plates")
    } else {
        check(assigned.isEmpty, "\(name): no course claims a plate")
    }
}

// MARK: - Result

print("")
if failures.isEmpty {
    print("PASS")
} else {
    print("FAIL (\(failures.count))")
    for failure in failures { print("  \(failure)") }
    exit(1)
}
