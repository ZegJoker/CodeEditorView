import Foundation
import os

/// Editor performance instrumentation (UI-008 / Phase 3).
public enum EditorSignposts: Sendable {
    public static let subsystem = "com.codeeditorview.editor"
    public static let category = "latency"

    private static let signposter = OSSignposter(
        logger: Logger(subsystem: subsystem, category: category)
    )

    public enum Interval: Sendable {
        case keystrokeLayout
        case highlightPaint
        case languageLoad
        case parseBackground

        var name: StaticString {
            switch self {
            case .keystrokeLayout: return "keystroke.layout"
            case .highlightPaint: return "highlight.paint"
            case .languageLoad: return "language.load"
            case .parseBackground: return "parse.background"
            }
        }
    }

    public static func begin(_ interval: Interval) -> OSSignpostIntervalState {
        signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
    }

    public static func end(_ interval: Interval, state: OSSignpostIntervalState) {
        signposter.endInterval(interval.name, state)
    }

    /// Measure a synchronous body and return elapsed seconds.
    @discardableResult
    public static func measure<T>(_ interval: Interval, body: () throws -> T) rethrows -> (T, TimeInterval) {
        let state = begin(interval)
        let start = ContinuousClock.now
        let value = try body()
        let elapsed = start.duration(to: ContinuousClock.now)
        end(interval, state: state)
        return (value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}

/// Provisional budgets for CI / local harness (not hardware-certified).
public enum EditorPerformanceBudgets: Sendable {
    /// Layout pass for a synthetic 1k-line wrap update on CI (seconds).
    public static let layout1kLinesSeconds: TimeInterval = 2.0
    /// Single keystroke edit+layout budget (seconds).
    public static let keystrokeLayoutSeconds: TimeInterval = 0.25
}

/// Simple in-process sample collector for tests.
public final class EditorPerformanceHarness: @unchecked Sendable {
    public private(set) var samples: [String: [TimeInterval]] = [:]
    private let lock = NSLock()

    public init() {}

    public func record(_ name: String, seconds: TimeInterval) {
        lock.lock()
        samples[name, default: []].append(seconds)
        lock.unlock()
    }

    public func p95(_ name: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard var values = samples[name], !values.isEmpty else { return nil }
        values.sort()
        let idx = min(values.count - 1, Int(Double(values.count - 1) * 0.95))
        return values[idx]
    }
}
