import CoreGraphics
import Foundation
import XCTest

/// SplitMix64 — a small, fast, seedable PRNG.
///
/// Swift's `SystemRandomNumberGenerator` cannot be seeded, so it can't produce a
/// reproducible tap sequence. SplitMix64 is a well-known, public-domain generator
/// (Steele, Lea & Flood) that's good enough for fuzzing/UI-test purposes and,
/// critically, deterministic: the same seed always produces the same sequence of
/// taps, swipes, and long-presses.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform double in [0, 1).
    mutating func nextDouble() -> Double {
        let bits = next() >> 11 // top 53 bits
        return Double(bits) * (1.0 / Double(1 << 53))
    }

    /// A uniform double in the given closed range.
    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
    }
}

/// One randomly-generated interaction. Coordinates are normalized (0...1)
/// relative to the app's window, since that's what `XCUICoordinate` wants and
/// it keeps actions valid across device sizes / orientations.
private struct MonkeyAction {
    enum Kind: String {
        case tap
        case swipe
        case longPress
    }

    let kind: Kind
    let primary: CGVector
    let secondary: CGVector?
    let pressDuration: TimeInterval?
}

/// AppleHammer's monkey-testing UI test.
///
/// Taps, swipes, and long-presses random points on screen for a fixed duration,
/// logging every action so a crash can be traced back to the exact sequence that
/// caused it. Controlled entirely through environment variables so `scripts/run.sh`
/// (and `xcodebuild test ... TEST_RUNNER_*`) can drive it without editing this file:
///
///   APPLEHAMMER_SEED         UInt64 seed for the PRNG (required for reproducibility;
///                           if unset, a timestamp-derived seed is used and printed)
///   APPLEHAMMER_DURATION      run length in seconds (default: 60)
///   APPLEHAMMER_LOG_DIR       directory to write action-log / crash-report / summary
///                           JSON files into (default: an AppleHammer folder in tmp)
///   APPLEHAMMER_LAUNCH_ARG    extra launch argument passed to the app under test
///                           (default: "--uitesting")
///
/// The host app should check for the `--uitesting` launch argument (or whatever
/// was passed via APPLEHAMMER_LAUNCH_ARG) at startup and skip login/onboarding,
/// disable analytics/crash-reporter prompts, and load fixture data instead of
/// hitting real network/auth — see SKILL.md.
final class MonkeyTests: XCTestCase {

    private var app: XCUIApplication!
    private var rng = SplitMix64(seed: 0)
    private var seed: UInt64 = 0
    private var duration: TimeInterval = 60
    private var logDir: URL!

    private var actionLogURL: URL!
    private var crashReportURL: URL!
    private var summaryURL: URL!
    private var actionLogHandle: FileHandle!

    private let recentActionsLimit = 10
    private var recentActions: [[String: Any]] = []
    private var actionCount = 0
    private var crashReportWritten = false

    private var interruptionMonitor: NSObjectProtocol?
    private let isoFormatter = ISO8601DateFormatter()

    // MARK: - Setup / teardown

    override func setUpWithError() throws {
        // Keep the loop running past ordinary XCTest assertion failures; crashes
        // and hangs are detected explicitly below via app.state and record(_:).
        continueAfterFailure = true

        let env = ProcessInfo.processInfo.environment
        seed = env["APPLEHAMMER_SEED"].flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970 * 1000)
        duration = env["APPLEHAMMER_DURATION"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 60
        let launchArg = env["APPLEHAMMER_LAUNCH_ARG"].flatMap { $0.isEmpty ? nil : $0 } ?? "--uitesting"

        logDir = env["APPLEHAMMER_LOG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("AppleHammer", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        rng = SplitMix64(seed: seed)

        actionLogURL = logDir.appendingPathComponent("action-log-\(seed).jsonl")
        crashReportURL = logDir.appendingPathComponent("crash-report-\(seed).json")
        summaryURL = logDir.appendingPathComponent("summary-\(seed).json")
        FileManager.default.createFile(atPath: actionLogURL.path, contents: nil)
        actionLogHandle = try FileHandle(forWritingTo: actionLogURL)

        app = XCUIApplication()
        app.launchArguments += [launchArg]

        // Auto-dismiss system alerts (location/notifications/camera permission
        // prompts, "Would You Like to Rate This App", etc.) so the monkey doesn't
        // stall waiting on a dialog it doesn't know how to answer.
        interruptionMonitor = addUIInterruptionMonitor(withDescription: "AppleHammer system alert handler") { alert in
            let commonButtons = ["Allow", "Allow While Using App", "Allow Once", "OK", "Continue", "Don't Allow", "Not Now", "Cancel"]
            for label in commonButtons {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            // Unknown alert: tap the first button so the monkey can keep moving.
            let firstButton = alert.buttons.firstMatch
            if firstButton.exists {
                firstButton.tap()
                return true
            }
            return false
        }

        app.launch()
        print("APPLEHAMMER_SEED=\(seed)")
        print("APPLEHAMMER_DURATION=\(duration)")
        print("APPLEHAMMER_LOG_DIR=\(logDir.path)")
    }

    override func tearDownWithError() throws {
        // Fallback: if the app is not in the foreground at teardown and nothing
        // else caught it, still leave a crash report behind.
        if !crashReportWritten, app != nil, app.state != .runningForeground {
            writeCrashReport(reason: "app.state at teardown was \(describe(app.state)), expected .runningForeground")
        }
        if let monitor = interruptionMonitor {
            removeUIInterruptionMonitor(monitor)
            interruptionMonitor = nil
        }
        try? actionLogHandle?.close()
    }

    /// Catches XCTest's own automatic failures — including crash and
    /// "app is not responding" (hang) detection — which otherwise abort the test
    /// method before our own loop gets a chance to notice.
    override func record(_ issue: XCTIssue) {
        writeCrashReport(reason: issue.compactDescription)
        super.record(issue)
    }

    // MARK: - The monkey

    func testMonkey() throws {
        let deadline = Date().addingTimeInterval(duration)
        var index = 0

        while Date() < deadline {
            guard app.state == .runningForeground else {
                writeCrashReport(reason: "app.state became \(describe(app.state)) (expected .runningForeground)")
                XCTFail("AppleHammer stopped early after \(index) actions: app is no longer in the foreground. seed=\(seed). See \(crashReportURL.path)")
                return
            }

            let action = nextAction()
            let entry = logEntry(for: action, index: index)
            perform(action)
            appendToActionLog(entry)
            remember(entry)

            index += 1
            actionCount = index
        }

        writeSummary(completed: true)
    }

    // MARK: - Action generation

    private func randomVector() -> CGVector {
        // Keep a small inset off the very edge of the screen so taps don't
        // constantly land on the status bar / home indicator.
        let inset = 0.03
        let dx = inset + rng.nextDouble() * (1 - inset * 2)
        let dy = inset + rng.nextDouble() * (1 - inset * 2)
        return CGVector(dx: dx, dy: dy)
    }

    private func nextAction() -> MonkeyAction {
        let roll = rng.nextDouble()
        switch roll {
        case ..<0.60:
            return MonkeyAction(kind: .tap, primary: randomVector(), secondary: nil, pressDuration: nil)
        case ..<0.85:
            return MonkeyAction(kind: .swipe, primary: randomVector(), secondary: randomVector(), pressDuration: nil)
        default:
            let pressDuration = rng.nextDouble(in: 0.5...2.0)
            return MonkeyAction(kind: .longPress, primary: randomVector(), secondary: nil, pressDuration: pressDuration)
        }
    }

    private func perform(_ action: MonkeyAction) {
        let start = app.coordinate(withNormalizedOffset: action.primary)
        switch action.kind {
        case .tap:
            start.tap()
        case .longPress:
            start.press(forDuration: action.pressDuration ?? 1.0)
        case .swipe:
            guard let secondary = action.secondary else { return }
            let end = app.coordinate(withNormalizedOffset: secondary)
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    // MARK: - Logging

    private func logEntry(for action: MonkeyAction, index: Int) -> [String: Any] {
        let frame = app.frame
        func absolute(_ v: CGVector) -> (Double, Double) {
            (Double(frame.minX + frame.width * v.dx), Double(frame.minY + frame.height * v.dy))
        }

        var entry: [String: Any] = [
            "index": index,
            "seed": String(seed),
            "type": action.kind.rawValue,
            "timestamp": isoFormatter.string(from: Date()),
        ]

        let (x, y) = absolute(action.primary)
        entry["x"] = x
        entry["y"] = y

        if let secondary = action.secondary {
            let (x2, y2) = absolute(secondary)
            entry["x2"] = x2
            entry["y2"] = y2
        }
        if let pressDuration = action.pressDuration {
            entry["durationSeconds"] = pressDuration
        }

        return entry
    }

    private func appendToActionLog(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        actionLogHandle.write(line)
    }

    private func remember(_ entry: [String: Any]) {
        recentActions.append(entry)
        if recentActions.count > recentActionsLimit {
            recentActions.removeFirst()
        }
    }

    private func writeCrashReport(reason: String) {
        guard !crashReportWritten else { return }
        crashReportWritten = true

        let report: [String: Any] = [
            "seed": String(seed),
            "durationRequested": duration,
            "actionCount": actionCount,
            "reason": reason,
            "detectedAt": isoFormatter.string(from: Date()),
            "lastActions": recentActions,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: crashReportURL)
        }
        print("APPLEHAMMER_CRASH_REPORT=\(crashReportURL.path)")
    }

    private func writeSummary(completed: Bool) {
        let summary: [String: Any] = [
            "seed": String(seed),
            "durationRequested": duration,
            "actionCount": actionCount,
            "completed": completed,
            "finishedAt": isoFormatter.string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: summaryURL)
        }
        print("APPLEHAMMER_SUMMARY=\(summaryURL.path)")
    }

    private func describe(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForegroundInactive: return "runningForegroundInactive"
        case .runningForeground: return "runningForeground"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
