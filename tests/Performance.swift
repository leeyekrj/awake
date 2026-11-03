
@MainActor enum PerformanceCounts {
    static var rootBodies = 0
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor func runPerformanceRegression() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    let iterations = Int(CommandLine.arguments[1])!
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        Task { @MainActor in
            if let monitor = delegate.globalMonitor { NSEvent.removeMonitor(monitor); delegate.globalMonitor = nil }
            if let monitor = delegate.localMonitor { NSEvent.removeMonitor(monitor); delegate.localMonitor = nil }
            let model = delegate.power
            // Simulate enabled state without creating assertions or changing lidawake.
            model.coffeeOn = true
            let base = Date()
            model.coffeeExpiry = base.addingTimeInterval(Double(iterations + 3600))
            delegate.showPanel()
            await pause(0.4)
            let rootBefore = PerformanceCounts.rootBodies
            let cpuBefore = Double(clock()) / Double(CLOCKS_PER_SEC)
            for i in 1...iterations {
                autoreleasepool {
                    model.now = base.addingTimeInterval(Double(i))
                    delegate.updateItem()
                    delegate.placePanel()
                }
                await pause(0.001)
            }
            await pause(0.05)
            let redraws = PerformanceCounts.rootBodies - rootBefore
            let cpu = Double(clock()) / Double(CLOCKS_PER_SEC) - cpuBefore
            print("Clock: \(iterations) rendered updates, \(redraws) full-panel body evaluations, CPU \(cpu)s")
            fflush(stdout)
            guard redraws == 0 else {
                fputs("FAIL: clock updates rebuild all controls\n", stderr)
                exit(1)
            }
            // Fixed-version lifecycle checks
            weak var oldHost = delegate.host
            delegate.hidePanel()
            await pause(0.35)
            precondition(delegate.host == nil && oldHost == nil, "closed panel retains its SwiftUI graph")

            var clockChanges = 0, rootChanges = 0
            let clockSubscription = model.displayClock.objectWillChange.sink { clockChanges += 1 }
            let rootSubscription = model.objectWillChange.sink { rootChanges += 1 }
            let hiddenBefore = PerformanceCounts.rootBodies
            for _ in 0..<172_800 { model.tick() }
            await pause(0.05)
            precondition(clockChanges == 0 && rootChanges == 0)
            precondition(PerformanceCounts.rootBodies == hiddenBefore && delegate.host == nil)
            withExtendedLifetime((clockSubscription, rootSubscription)) {}
            print("PASS: 172800 hidden timer ticks, zero display updates; old host deallocated")

            // Deadline handling keeps running even while display updates are paused.
            model.coffeeExpiry = Date().addingTimeInterval(-1)
            model.tick()
            precondition(!model.coffeeOn, "hidden panel paused session expiration")

            for _ in 0..<10 {
                delegate.showPanel()
                await pause(0.03)
                delegate.hidePanel()
                await pause(0.03)
                delegate.showPanel()
                await pause(0.3)
                precondition(delegate.host != nil && delegate.isPanelOpen && model.clockVisible)
                precondition(abs(model.now.timeIntervalSinceNow) < 1)
                weak var host = delegate.host
                delegate.hidePanel()
                await pause(0.2)
                precondition(delegate.host == nil && host == nil && !model.clockVisible)
            }
            print("PASS: interrupted close/open animations and 10 host release cycles")

            delegate.showPanel()
            await pause(0.3)
            let collapsed = delegate.panel.frame.height
            delegate.toggleSettings()
            await pause(0.4)
            let expanded = delegate.panel.frame.height
            precondition(expanded > collapsed && model.settingsOpen && model.settingsReveal == 1)
            delegate.hidePanel()
            await pause(0.2)
            delegate.showPanel()
            await pause(0.3)
            precondition(model.settingsOpen && abs(delegate.panel.frame.height - expanded) < 1)
            delegate.toggleSettings()
            await pause(0.4)
            precondition(abs(delegate.panel.frame.height - collapsed) < 1)
            delegate.hidePanel()
            await pause(0.3)
            precondition(delegate.host == nil)
            print("PASS: settings size/state survive panel recreation; hidden deadlines still expire")
            model.defaults.removePersistentDomain(forName: "io.paul.awake.performance.\(getpid())")
            print("PASS: performance regression complete")
            fflush(stdout)
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
MainActor.assumeIsolated { runPerformanceRegression() }
