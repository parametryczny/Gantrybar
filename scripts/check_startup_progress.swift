// Compile with Sources/Gantry/App/StartupConnectionProgress.swift; no app or network needed.
@main struct StartupProgressCheck {
    static func main() {
        var empty = StartupConnectionProgress(serials: [])
        precondition(!empty.isLoading)
        empty.receivedTelemetry(from: "new")
        precondition(!empty.isLoading)

        for total in 1...12 {
            var progress = StartupConnectionProgress(serials: (1...total).map(String.init))
            let threshold = (total * 3 + 4) / 5
            progress.receivedTelemetry(from: "unknown")
            precondition(progress.ready == 0)
            for index in 1...threshold {
                progress.receivedTelemetry(from: String(index))
                progress.receivedTelemetry(from: String(index))
                precondition(progress.ready == index, "Repeated data counted twice")
                precondition(progress.isLoading == (index < threshold), "Wrong 60% threshold")
            }
            progress.receivedTelemetry(from: "unknown")
            precondition(!progress.isLoading, "Finished launch restarted")
        }
        var timeout = StartupConnectionProgress(serials: ["a", "b", "c", "d", "e"])
        timeout.receivedTelemetry(from: "a")
        timeout.finish() // same path for the timeout and the user's skip action
        timeout.receivedTelemetry(from: "b")
        precondition(!timeout.isLoading)
        var removed = StartupConnectionProgress(serials: ["a", "b"])
        removed.receivedTelemetry(from: "a")
        removed.remove("b")
        precondition(!removed.isLoading)
        precondition(StartupConnectionProgress.timeout == 15)
        print("PASS: empty fleet, 60% for 1–12 printers, duplicate/unknown telemetry, timeout/skip, removal, one-shot completion")
    }
}
