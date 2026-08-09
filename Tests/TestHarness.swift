import Foundation

/// Minimalny harness testowy.
///
/// Narzędzia wiersza poleceń Xcode nie zawierają XCTest ani Swift Testing, a aplikacja
/// z założenia nie ma zewnętrznych zależności — testy uruchamiane są więc jako zwykły
/// program (`scripts/run-tests.sh`), który kończy się kodem 1 przy pierwszym niepowodzeniu.
enum T {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentSuite = ""
    nonisolated(unsafe) static var currentTest = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        do {
            try body()
        } catch {
            fail("nieoczekiwany wyjątek w zestawie: \(error)")
        }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        let before = failures.count
        do {
            try body()
        } catch {
            fail("nieoczekiwany wyjątek: \(error)")
        }
        if failures.count == before {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(name)")
        }
    }

    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let location = "\((String(describing: file) as NSString).lastPathComponent):\(line)"
        let entry = "\(currentSuite) › \(currentTest): \(message)  [\(location)]"
        failures.append(entry)
        print("  \u{001B}[31m✗\u{001B}[0m \(currentTest): \(message)  [\(location)]")
    }

    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        if !condition { fail(message, file: file, line: line) }
    }

    static func equal<Value: Equatable>(_ actual: Value, _ expected: Value, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        if actual != expected {
            fail("\(label): oczekiwano \(expected), otrzymano \(actual)", file: file, line: line)
        }
    }

    static func notNil<Value>(_ value: Value?, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        if value == nil { fail("\(label): oczekiwano wartości, otrzymano nil", file: file, line: line) }
    }

    static func isNil<Value>(_ value: Value?, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        if value != nil { fail("\(label): oczekiwano nil, otrzymano \(String(describing: value!))", file: file, line: line) }
    }

    static func throwsError(_ label: String, _ body: () throws -> Void,
                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            fail("\(label): oczekiwano błędu, operacja zakończyła się powodzeniem", file: file, line: line)
        } catch {
            // Oczekiwany przebieg.
        }
    }

    /// Uruchamia asynchroniczny fragment testu w kontekście synchronicznym.
    static func runAsync<Value>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Value, Error>?
        Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch result! {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    static func report() -> Int32 {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32mWszystkie testy przeszły: \(passed)\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31mNiepowodzenia: \(failures.count) (przeszło: \(passed))\u{001B}[0m")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}
