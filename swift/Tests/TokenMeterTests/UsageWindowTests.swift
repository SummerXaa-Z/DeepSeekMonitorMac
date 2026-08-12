import Foundation
import XCTest
@testable import TokenMeter

final class UsageWindowTests: XCTestCase {
    func testClaudeModelAndProjectRankingsExcludeOldEventsInAnActiveFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("active.jsonl")
        try write(
            """
            {"type":"assistant","timestamp":"2026-07-29T12:00:00.000Z","requestId":"old-request","cwd":"/tmp/legacy-project","message":{"id":"old-message","model":"legacy-model","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
            {"type":"assistant","timestamp":"2026-08-05T12:00:00.000Z","requestId":"current-request","cwd":"/tmp/current-project","message":{"id":"current-message","model":"current-model","usage":{"input_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}
            """,
            to: file,
            modificationDate: now
        )

        let result = ClaudeUsage.load(projectsDirectory: directory, now: now)

        XCTAssertEqual(result.weekTotal, 10)
        XCTAssertEqual(
            result.models,
            [ClaudeModelUsage(model: "current-model", totalTokens: 10, outputTokens: 2, messageCount: 1)]
        )
        XCTAssertEqual(
            result.projects,
            [ClaudeProjectUsage(project: "current-project", totalTokens: 10, messageCount: 1)]
        )
    }

    func testCodexModelRankingExcludesOldEventsInAnActiveFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        try write(
            """
            {"timestamp":"2026-07-29T12:00:00.000Z","payload":{"type":"turn_context","model":"legacy-model","cwd":"/tmp/test-project"}}
            {"timestamp":"2026-07-29T12:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":100}}}}
            {"timestamp":"2026-08-05T12:00:00.000Z","payload":{"type":"turn_context","model":"current-model","effort":"high"}}
            {"timestamp":"2026-08-05T12:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":110,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":110}}}}
            """,
            to: file,
            modificationDate: now
        )

        let result = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertEqual(result.weekTotal, 10)
        XCTAssertEqual(
            result.models,
            [CodexModelUsage(model: "current-model (high)", totalTokens: 10)]
        )
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.totalTokens }, result.weekTotal)
    }

    func testClaudeCountsAnUnterminatedLastJSONLLine() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("active.jsonl")
        try write(
            """
            {"type":"assistant","timestamp":"2026-08-06T12:00:00.000Z","requestId":"current-request","cwd":"/tmp/current-project","message":{"id":"current-message","model":"current-model","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}
            """,
            to: file,
            modificationDate: now,
            trailingNewline: false
        )

        let result = ClaudeUsage.load(projectsDirectory: directory, now: now)

        XCTAssertEqual(result.weekTotal, 7)
        XCTAssertEqual(result.models.map(\.model), ["current-model"])
        XCTAssertEqual(result.projects.map(\.project), ["current-project"])
    }

    func testCodexCountsAnUnterminatedLastJSONLLine() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        try write(
            """
            {"timestamp":"2026-08-06T12:00:00.000Z","payload":{"type":"turn_context","model":"current-model","cwd":"/tmp/current-project"}}
            {"timestamp":"2026-08-06T12:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":7}}}}
            """,
            to: file,
            modificationDate: now,
            trailingNewline: false
        )

        let result = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertEqual(result.weekTotal, 7)
        XCTAssertEqual(result.models, [CodexModelUsage(model: "current-model", totalTokens: 7)])
        XCTAssertEqual(result.projects, [CodexProjectUsage(project: "current-project", totalTokens: 7, sessionCount: 1)])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(
        _ contents: String,
        to file: URL,
        modificationDate: Date,
        trailingNewline: Bool = true
    ) throws {
        try (contents + (trailingNewline ? "\n" : "")).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)
    }

    private func fixedDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
