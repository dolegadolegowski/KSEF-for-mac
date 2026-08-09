import Foundation

// Punkt wejścia zestawu testów. Uruchamiany przez `scripts/run-tests.sh`.
//
// Testy wykonują się na wątku pobocznym, a wątek główny obsługuje pętlę zdarzeń.
// Bez tego fragmenty testów oczekujące na pracę wykonywaną na `MainActor`
// (model aplikacji) zakleszczyłyby się z semaforem w `T.runAsync`.
print("Testy \(AppInfo.displayVersion)")
print(String(repeating: "═", count: 60))

let finished = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 0

Thread.detachNewThread {
    CoreTests.run()
    ParserTests.run()
    CryptoTests.run()
    ClientTests.run()
    PdfTests.run()
    MailTests.run()
    AppModelTests.run()
    UpdateTests.run()

    exitCode = T.report()
    finished.signal()
}

while finished.wait(timeout: .now() + 0.02) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}

exit(exitCode)
