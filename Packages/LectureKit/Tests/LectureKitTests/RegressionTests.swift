import Foundation
import Testing

@testable import LectureKit

/// What a lecture note looked like before readings existed.
///
/// Every note in the vault is rewritten through `NoteRenderer.render`, and the
/// detection prompt was tuned against real transcripts. Both are the kind of
/// thing that drifts by a character during unrelated work and produces no
/// visible symptom until a term of notes has been rewritten wrongly. These two
/// tests exist to make that drift loud.
@Suite("Regression: pre-readings behaviour")
struct RegressionTests {

    @Test("a lecture note renders byte-for-byte as it did before readings")
    func lectureRenderIsUnchanged() {
        let note = LectureNote(
            date: "2026-09-02",
            course: "CS 314H",
            topic: "Binary search trees",
            sections: ["- live"],
            finalNotes: "## Summary\n\nTrees.",
            transcript: "raw words",
            duration: 3_180,
            detectedCourse: "CS 314H",
            detectionConfidence: .high)

        let expected = """
            ---
            title: "Binary search trees"
            course: CS 314H
            date: 2026-09-02
            type: lecture
            duration_min: 53
            status: complete
            detected_course: CS 314H
            detection_confidence: high
            tags:
              - lecture
              - cs-314h
            ---
            # Binary search trees

            **CS 314H** · 2026-09-02

            ## Summary

            Trees.

            ---

            ## Transcript

            raw words

            """

        #expect(NoteRenderer().render(note, keepTranscript: true) == expected)
    }

    @Test("the lecture detection prompt is unchanged")
    func detectionPromptIsUnchanged() {
        // Detection quality was tuned against real transcripts. A reworded
        // prompt is a silent quality regression, so the literal is pinned here
        // rather than trusted to review.
        let expected = """
            You identify which university course a lecture transcript belongs to.

            Reply with ONLY a JSON object, no prose and no code fence:
            {"course": "<course code>", "confidence": "high"|"low", "topic": "<3-6 word topic>"}

            Rules:
            - Prefer a course from the provided list. Use its code EXACTLY as given.
            - Only invent a new course code if the material clearly fits none of them. Use the
              code the lecturer says (e.g. "CS 314H"), or a short subject name if none is said.
            - confidence is "high" only if the subject matter clearly matches one course.
              A generic or administrative transcript is "low".
            - topic is what THIS lecture covered, for use as a filename: title case, no dates,
              no course code, no punctuation beyond spaces and hyphens.
            - The transcript is ASR output and may contain errors.
            """

        #expect(CourseDetector.detectSystem == expected)
    }
}
