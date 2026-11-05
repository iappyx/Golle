import Foundation

// `Golle --test` runs the unit tests and exits with the number of failures (see Testing/).
if CommandLine.arguments.contains("--test") {
    let failures = MainActor.assumeIsolated { TestRunner.run() }
    exit(failures == 0 ? 0 : 1)
}

// `Golle --screenshots <folder>` draws demo windows into PNGs (see Testing/Screenshots.swift).
if let index = CommandLine.arguments.firstIndex(of: "--screenshots"), index + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let appearance = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : nil
    MainActor.assumeIsolated { Screenshots.run(into: folder, appearance: appearance) }
}

GolleApp.main()
