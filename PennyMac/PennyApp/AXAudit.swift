import AppKit

/// TestMode-only launch fix: macOS remembers which Space an app's windows live
/// on and reopens them there — for XCUITest launches that can be a Space the
/// automation session isn't looking at (window exists, `onscreen=false`), so
/// snapshots, events and recordings all target an empty desktop and time out.
/// Give the window "move to the active Space" behaviour and activate hard.
enum TestWindowFix {
    static func applyIfTesting() {
        guard TestMode.active else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where w.level == .normal {
                w.collectionBehavior.insert(.moveToActiveSpace)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// TEMPORARY diagnostic (TestMode-gated, inert in normal launches): walks the
/// app's OWN accessibility tree via the NSAccessibility protocol and prints
/// element counts, per-subtree timing, repeat visits (cycles!) and child-count
/// explosions. External XCTest snapshots serialize this same tree; if they
/// hang, the pathology shows up here — with no AX permissions needed, because
/// the walk is in-process.
enum AXAudit {
    static func runIfRequested() {
        guard TestMode.active,
              ProcessInfo.processInfo.arguments.contains("--uitest-ax-audit") else { return }
        // Give the launch-time import time to land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { walkAll() }
    }

    /// stderr is unbuffered — a redirected GUI app's stdout is fully buffered
    /// and its contents die with the process.
    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    private static func walkAll() {
        var count = 0
        var maxDepth = 0
        var seen = Set<ObjectIdentifier>()
        var cycles = 0
        var slow: [(Double, String)] = []
        let started = Date()

        func describe(_ obj: AnyObject) -> String {
            let role = (obj as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "?"
            let id = (obj as? NSAccessibilityProtocol)?.accessibilityIdentifier() ?? ""
            let label = (obj as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
            return "\(type(of: obj))/\(role) id='\(id.prefix(28))' l='\(label.prefix(36))'"
        }

        func walk(_ obj: AnyObject, _ depth: Int) {
            let key = ObjectIdentifier(obj)
            if seen.contains(key) {
                cycles += 1
                if cycles < 10 { log("AXAUDIT CYCLE at depth \(depth): \(describe(obj))") }
                return
            }
            seen.insert(key)
            count += 1
            maxDepth = max(maxDepth, depth)
            if depth > 100 {
                log("AXAUDIT MAX-DEPTH at \(describe(obj))")
                return
            }
            let t0 = Date()
            let kids = (obj as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            let dt = Date().timeIntervalSince(t0)
            if dt > 0.1 { slow.append((dt, "\(describe(obj)) children=\(kids.count)")) }
            if kids.count > 500 { log("AXAUDIT HUGE-CHILDREN \(kids.count) at \(describe(obj))") }
            for k in kids { walk(k as AnyObject, depth + 1) }
        }

        for (i, window) in NSApp.windows.enumerated() {
            log("AXAUDIT window[\(i)] '\(window.title)' visible=\(window.isVisible)")
            walk(window, 0)
        }
        log(String(format: "AXAUDIT COMPLETE: %d elements, depth %d, cycles %d, %.2fs",
                     count, maxDepth, cycles, Date().timeIntervalSince(started)))
        for (dt, d) in slow.sorted(by: { $0.0 > $1.0 }).prefix(10) {
            log(String(format: "AXAUDIT SLOW %.3fs %@", dt, d))
        }
    }
}
