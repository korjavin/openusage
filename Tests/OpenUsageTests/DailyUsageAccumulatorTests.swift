import XCTest
@testable import OpenUsage

/// Direct pins for the shared accumulate-then-assemble contract behind the Claude/Codex/Grok scanners
/// (the class of drift behind the ccusage false-zero fix): one `dayKey` spelling, newest-first day
/// order, per-model accumulation, and unpriced models counted with no cost.
final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedCalendarAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — pads month and day to two digits.
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // The key is local-calendar: one instant, two time zones, two different days.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // Every counted day is priced — a real cost, never nil-by-omission.
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testUnpricedModelTokensCountWithNilCost() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "gemini-4-argon-trial", tokens: 500)
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.addUnknownModel(day: "2024-06-01", model: "mystery-model", tokens: 40)
        // A warning-only call (a fallback estimate already counted the tokens) adds no tokens.
        accumulator.addUnknownModel(day: "2024-06-01", model: "fallback-model")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [500, 140])
        // An all-unpriced day has no cost rather than a false $0; a mixed day keeps its priced total.
        XCTAssertNil(scan.series.daily[0].costUSD)
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 1.0, accuracy: 0.0001)

        let june2 = scan.modelUsage?.daily.first { $0.date == "2024-06-02" }?.models
        XCTAssertEqual(june2, [ModelUsageEntry(model: "gemini-4-argon-trial", totalTokens: 500, costUSD: nil)])
        XCTAssertEqual(scan.unknownModelsByDay["2024-06-01"], ["mystery-model", "fallback-model"])

        // Merging replays unpriced entries instead of dropping their tokens.
        let merged = DailyUsageAccumulator.merged([scan, nil])
        XCTAssertEqual(merged?.series.daily.map(\.totalTokens), [500, 140])
        XCTAssertNil(merged?.series.daily[0].costUSD)
        XCTAssertEqual(merged?.unknownModelsByDay, scan.unknownModelsByDay)
    }
}
