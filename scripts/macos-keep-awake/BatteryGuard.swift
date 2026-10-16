import Foundation
import IOKit.ps

// Sleep between IOKit power-source notifications; no periodic battery polling.
func shouldStop(ac: Bool, percent: Int?, limit: Int) -> Bool {
    if ac { return false }
    guard let percent else { return true }
    return limit == 100 || percent <= limit
}

func currentPower() -> (Bool, Int?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return (false, nil)
    }
    for source in sources {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        let ac = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        guard let current = d[kIOPSCurrentCapacityKey] as? Int,
              let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return (ac, nil) }
        return (ac, max(0, min(100, current * 100 / maximum)))
    }
    return (false, nil)
}

final class BatteryGuard {
    let script: String
    let limit: Int
    var retry: Timer?

    init(script: String, limit: Int) { self.script = script; self.limit = limit }

    func check() {
        let (ac, percent) = currentPower()
        guard shouldStop(ac: ac, percent: percent, limit: limit) else {
            retry?.invalidate(); retry = nil
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "stop", "--automatic"]
        process.standardInput = FileHandle.nullDevice
        // launchd normally terminates this process as the final step of stop.
        do {
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0 { exit(0) }
        } catch { fputs("Battery guard: \(error)\n", stderr) }
        // Permission/lock failures are retried, with a coalescible timer only on error.
        if retry == nil {
            retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
            retry?.tolerance = 10
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    precondition(!shouldStop(ac: true, percent: 5, limit: 20))
    precondition(!shouldStop(ac: false, percent: 21, limit: 20))
    precondition(shouldStop(ac: false, percent: 20, limit: 20))
    precondition(shouldStop(ac: false, percent: 0, limit: 20))
    precondition(shouldStop(ac: false, percent: nil, limit: 20))
    precondition(shouldStop(ac: false, percent: 99, limit: 100))
    let (ac, percent) = currentPower()
    print("BatteryGuard policy passed; AC=\(ac), battery=\(percent.map(String.init) ?? "unknown")")
    exit(0)
}

guard CommandLine.arguments.count == 3,
      let limit = Int(CommandLine.arguments[2]), [20, 100].contains(limit) else { exit(2) }
let guardProcess = BatteryGuard(script: CommandLine.arguments[1], limit: limit)
guard let source = IOPSNotificationCreateRunLoopSource({ context in
    guard let context else { return }
    Unmanaged<BatteryGuard>.fromOpaque(context).takeUnretainedValue().check()
}, Unmanaged.passUnretained(guardProcess).toOpaque())?.takeRetainedValue() else { exit(1) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
guardProcess.check()
CFRunLoopRun()
