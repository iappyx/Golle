import Foundation

/// A very small test runner. Golle builds without Xcode, so XCTest isn't used; tests run through
/// the app binary instead (`Golle --test`, or scripts/test.sh) and report with an exit code.
@MainActor
enum TestRunner {
    private struct Failure {
        let suite: String
        let message: String
        let file: String
        let line: UInt
    }

    private static var failures: [Failure] = []
    private static var currentSuite = ""
    private static var checks = 0
    private static var suites = 0

    static func suite(_ name: String, _ body: @MainActor () -> Void) {
        currentSuite = name
        suites += 1
        let before = failures.count
        body()
        let failed = failures.count - before
        print("\(failed == 0 ? "ok  " : "FAIL") \(name)\(failed == 0 ? "" : " — \(failed) failed)")")
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                       file: String = #fileID, line: UInt = #line) {
        checks += 1
        if !condition { failures.append(Failure(suite: currentSuite, message: message(), file: file, line: line)) }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "",
                                    file: String = #fileID, line: UInt = #line) {
        expect(actual == expected, "\(label.isEmpty ? "" : label + ": ")got \(actual), expected \(expected)", file: file, line: line)
    }

    /// Runs every suite; returns the number of failures.
    static func run() -> Int {
        failures = []
        checks = 0
        suites = 0
        // The defaults, not the user's Settings.
        let suite = "golle.tests.\(UUID().uuidString)"
        Preferences.store = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        Tests.all()

        print("")
        for failure in failures {
            print("FAIL \(failure.suite) (\(failure.file):\(failure.line)): \(failure.message)")
        }
        print("\(checks - failures.count)/\(checks) checks passed in \(suites) suites")
        return failures.count
    }
}
