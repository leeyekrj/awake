import AppKit
import SwiftUI
import Combine
import IOKit.pwr_mgt
import Security

// One interruptible clock drives both the SwiftUI reveal and native window geometry.
@MainActor final class ProgressAnimator {
    private var timer: Timer?
    var running: Bool { timer != nil }
    func stop() { timer?.invalidate(); timer = nil }
    static func eased(_ progress: Double) -> Double {
        // cubic-bezier(0.2, 0, 0, 1): quick response, gentle landing, no bounce.
        let x = min(1, max(0, progress))
        if x == 0 || x == 1 { return x }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2, u = 1 - t
            let sample = 3 * u * u * t * 0.2 + t * t * t
            if sample < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
    func animate(from: Double, to: Double, duration: Double, update: @escaping (Double) -> Void, completion: @escaping () -> Void = {}) {
        stop()
        guard duration > 0, abs(from - to) > 0.0001 else { update(to); completion(); return }
        let started = ProcessInfo.processInfo.systemUptime
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let fraction = min(1, elapsed / duration)
                update(from + (to - from) * Self.eased(fraction))
                if fraction >= 1 { self.stop(); completion() }
            }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let power = PowerController()
    var item: NSStatusItem!
    var panel: MenuPanel!
    var host: NSHostingView<PanelView>!
    let scroll = NSScrollView()
    var subscription: AnyCancellable?
    var globalMonitor: Any?
    var localMonitor: Any?
    var quitting = false
    var isPanelOpen = false
    var visibilityProgress = 0.0
    var lastAnchor: NSRect?
    var openRequest = UUID()
    let visibilityAnimator = ProgressAnimator()
    let settingsAnimator = ProgressAnimator()
    var motionSamples: [[String: Double]] = []
    var capturedMotionFrames: Set<Int> = []
    var measuredSettingsSignature = ""
    var displayedItemOn: Bool?
    var displayedItemTitle: String?
    var setupWindow: NSWindow?
    var setupController: SetupController?
    let motionReview = CommandLine.arguments.contains("--motion-review")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if (power.restoreLoginOnLaunch || CommandLine.arguments.contains("--restore-login")) && !power.loginEnabled {
            power.toggleLogin(true); power.writeRuntimeSnapshot()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 16; scroll.layer?.masksToBounds = true
        panel.contentView = scroll
        subscription = power.objectWillChange.debounce(for: .milliseconds(15), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self, self.panel.isVisible, !self.settingsAnimator.running else { return }
            self.placePanel()
        }
        power.stateChanged = { [weak self] in self?.updateItem() }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            if !self.anchorRect().contains(NSEvent.mouseLocation) { self.hidePanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hidePanel(); return nil }
            if event.type != .keyDown, event.window !== self.panel, !self.anchorRect().contains(NSEvent.mouseLocation) { self.hidePanel() }
            return event
        }
        updateItem()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(revealRequested), name: Notification.Name("io.paul.awake.show-panel"), object: nil)
        if CommandLine.arguments.contains("--motion-playback") {
            DispatchQueue.main.async { self.runMotionPlayback() }
        } else if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { self.showPanel() }
        }
        Task {
            await power.refresh(checkWatchdog: true)
            if CommandLine.arguments.contains("--setup") { showSetup() }
            else if !power.defaults.bool(forKey: "setupCompleted") && !power.defaults.bool(forKey: "setupDeferred") {
                if power.helperInstalled && power.watchdogReady && power.helperAuthorized && HotspotSettings.load() != nil {
                    power.defaults.set(true, forKey: "setupCompleted")
                } else { showSetup() }
            }
        }
    }
    func ensurePanelContent() {
        guard host == nil else { return }
        host = NSHostingView(rootView: PanelView(power: power, quit: { NSApp.terminate(nil) }, toggleSettings: { [weak self] in self?.toggleSettings() }, openSetup: { [weak self] in self?.showSetup() }))
        // Width and window geometry are managed here; avoid redundant min/max probes.
        host.sizingOptions = [.intrinsicContentSize]
        scroll.documentView = host
    }
    func showSetup() {
        hidePanel()
        if let window = setupWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let setup = SetupController(power: power)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Awake 설정"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(setup: setup, power: power))
        setup.requestClose = { [weak self, weak window] in window?.close(); self?.showPanel() }
        setupController = setup; setupWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !(setupController?.busy ?? false) }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === setupWindow {
            if setupController?.step != .done { power.defaults.set(true, forKey: "setupDeferred") }
            setupWindow = nil; setupController = nil
        }
    }
    func anchorRect() -> NSRect {
        guard let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return lastAnchor ?? .zero }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Status items briefly have a zero/stale frame while macOS lays out the bar.
        if !rect.isEmpty && rect.maxY >= screen.frame.maxY - 80 {
            lastAnchor = rect
            return rect
        }
        return lastAnchor ?? .zero
    }
    // Keep the TOP edge anchored below the menu bar even when content grows.
    // NSPopover's automatic SwiftUI sizing could move the top off screen.
    func placePanel() {
        guard let host else { return }
        let anchor = anchorRect()
        guard !anchor.isEmpty else { return }
        guard let screen = item.button?.window?.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let top = min(anchor.minY - 8, visible.maxY - 8) + (1 - visibilityProgress) * 6
        let signature = "\(power.hotspotWarning ?? "")/\(power.loginNeedsApproval)/\(power.stopCoffeeWithLid)"
        if power.settingsOpen && measuredSettingsSignature != signature {
            measuredSettingsSignature = signature
            power.settingsExpandedHeight = PanelView(power: power, quit: {}).measuredSettingsHeight()
        }
        host.layoutSubtreeIfNeeded()
        let desired = host.fittingSize
        let width = min(356, visible.width - 24)
        let height = min(desired.height, max(100, top - visible.minY - 12))
        let x = max(visible.minX + 12, min(anchor.midX - width / 2, visible.maxX - width - 12))
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
        let moved = panel.frame != frame
        let changed = panel.frame.size != frame.size
        let documentFrame = NSRect(origin: .zero, size: NSSize(width: width, height: desired.height))
        if host.frame != documentFrame { host.frame = documentFrame }
        if moved { panel.setFrame(frame, display: true) }
        if changed { scroll.contentView.scroll(to: NSPoint(x: 0, y: host.isFlipped ? 0 : max(0, desired.height - height))); scroll.reflectScrolledClipView(scroll.contentView) }
        assert(visible.contains(frame), "Awake panel must remain inside the visible screen")
        let report = "visible=\(visible) anchor=\(anchor) panel=\(frame) desired=\(desired) inside=\(visible.contains(frame))\n"
        if moved && !visibilityAnimator.running && !settingsAnimator.running { try? report.write(to: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/awake-panel-layout.log"), atomically: true, encoding: .utf8) }
        if motionReview && motionSamples.count < 2000 {
            let bucket = Int(power.settingsReveal * 4)
            if [1, 2, 3].contains(bucket), !capturedMotionFrames.contains(bucket),
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                capturedMotionFrames.insert(bucket)
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/awake-settings-motion-\(bucket).png"))
            }
            motionSamples.append(["time": ProcessInfo.processInfo.systemUptime, "top": panel.frame.maxY,
                "bottom": panel.frame.minY, "height": panel.frame.height, "settings": power.settingsReveal,
                "visibility": visibilityProgress, "alpha": panel.alphaValue, "inside": visible.contains(panel.frame) ? 1 : 0])
        }
    }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func saveMotionReview() {
        guard motionReview, let data = try? JSONSerialization.data(withJSONObject: motionSamples, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/awake-motion-review.json"))
    }
    func showPanel() {
        ensurePanelContent()
        power.now = Date()
        power.clockVisible = true
        isPanelOpen = true
        openRequest = UUID()
        revealWhenReady(request: openRequest)
    }
    func revealWhenReady(request: UUID, attempt: Int = 0) {
        guard isPanelOpen, request == openRequest else { return }
        if anchorRect().isEmpty {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.revealWhenReady(request: request, attempt: attempt + 1) }
            }
            return
        }
        panel.ignoresMouseEvents = false
        panel.alphaValue = visibilityProgress
        placePanel()
        panel.makeKeyAndOrderFront(nil)
        visibilityAnimator.animate(from: visibilityProgress, to: 1, duration: reduceMotion ? 0 : 0.20) { [weak self] value in
            guard let self else { return }
            self.visibilityProgress = value; self.panel.alphaValue = value; self.placePanel()
        } completion: { [weak self] in self?.saveMotionReview() }
        Task { await power.refresh(checkWatchdog: true) }
    }
    func hidePanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        power.clockVisible = false
        panel.ignoresMouseEvents = true
        visibilityAnimator.animate(from: visibilityProgress, to: 0, duration: reduceMotion ? 0 : 0.14) { [weak self] value in
            guard let self else { return }
            self.visibilityProgress = value; self.panel.alphaValue = value; self.placePanel()
        } completion: { [weak self] in
            guard let self, !self.isPanelOpen else { return }
            self.panel.orderOut(nil); self.panel.ignoresMouseEvents = false; self.saveMotionReview()
            // Hidden panels must not retain a live SwiftUI graph for days.
            self.scroll.documentView = nil
            self.host = nil
        }
    }
    @objc func revealRequested(_ notification: Notification) {
        if notification.userInfo?["setup"] as? Bool == true {
            showSetup()
            if let path = notification.userInfo?["capturePath"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let view = self?.setupWindow?.contentView else { return }
                    view.layoutSubtreeIfNeeded(); view.display()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            return
        }
        showPanel()
        if notification.userInfo?["settings"] as? Bool == true && !power.settingsOpen { toggleSettings() }
        if let path = notification.userInfo?["capturePath"] as? String {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.placePanel(); self.host.layoutSubtreeIfNeeded(); self.host.display()
                if let bitmap = self.host.bitmapImageRepForCachingDisplay(in: self.host.bounds) {
                    self.host.cacheDisplay(in: self.host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
    func toggleSettings() {
        power.settingsExpandedHeight = PanelView(power: power, quit: {}).measuredSettingsHeight()
        power.settingsOpen.toggle()
        let target = power.settingsOpen ? 1.0 : 0.0
        settingsAnimator.animate(from: power.settingsReveal, to: target, duration: reduceMotion ? 0 : 0.26) { [weak self] value in
            guard let self else { return }
            self.power.settingsReveal = value
            if self.panel.isVisible { self.placePanel() }
        } completion: { [weak self] in self?.saveMotionReview() }
    }
    func runMotionPlayback() {
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { self.toggleSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) { self.toggleSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.12) { self.toggleSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) { self.toggleSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.60) { self.hidePanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.66) { self.showPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.10) { self.hidePanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.50) { self.showPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { self.saveMotionReview() }
    }
    func updateItem() {
        let on = power.anyOn
        if displayedItemOn != on {
            let icon = on ? "cup.and.saucer.fill" : "cup.and.saucer"
            item.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "Awake")
            item.button?.image?.isTemplate = true
            item.button?.toolTip = on ? "Awake · 잠자기 방지 중" : "Awake · 잠자기 방지 꺼짐"
            displayedItemOn = on
        }
        let title: String
        if let expiry = power.nearestExpiry, power.anyOn {
            let minutes = max(0, Int(ceil(expiry.timeIntervalSinceNow / 60)))
            title = " \(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")"
        } else { title = "" }
        if displayedItemTitle != title { item.button?.title = title; displayedItemTitle = title }
    }
    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            hidePanel()
            let menu = NSMenu()
            let coffee = NSMenuItem(title: power.coffeeOn ? "잠자기 방지 끄기" : "잠자기 방지 켜기", action: #selector(quickCoffee), keyEquivalent: "")
            coffee.target = self; menu.addItem(coffee)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Awake 종료", action: #selector(quitApp), keyEquivalent: "")
            quit.target = self; menu.addItem(quit)
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
            return
        }
        isPanelOpen ? hidePanel() : showPanel()
    }
    @objc func quickCoffee() { power.toggleCoffee() }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        Task {
            let clean = await power.prepareToQuit()
            if clean { quitting = true; sender.reply(toApplicationShouldTerminate: true) }
            else { showPanel(); sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

@MainActor func renderPreviews(_ directory: String) {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
        for variant in ["idle", "active", "settings", "error", "custom-coffee", "custom-lid"] {
            let active = variant == "active"
            let model = PowerController(monitor: false)
            model.battery = 78; model.onAC = true; model.watchdogReady = true
            model.coffeeMinutes = 60; model.lidMinutes = 60; model.screenOn = active
            model.coffeeCustomSelected = false; model.lidCustomSelected = false
            model.settingsOpen = variant == "settings"
            model.settingsReveal = model.settingsOpen ? 1 : 0
            model.settingsExpandedHeight = PanelView(power: model, quit: {}).measuredSettingsHeight()
            if variant == "custom-coffee" { model.beginCustomDuration(.coffee) }
            if variant == "custom-lid" { model.beginCustomDuration(.lid) }
            if variant == "error" { model.error = "배터리가 19%라 켤 수 없어요. 충전하거나 보호 기준을 낮춰 주세요." }
            if active {
                model.coffeeOn = true; model.coffeeExpiry = Date().addingTimeInterval(43 * 60 + 12)
                model.lid = LidState(expiry: Date().addingTimeInterval(45 * 60 + 37), floor: 30, scope: "-a")
                model.lidEffective = true
            }
            let host = NSHostingView(rootView: PanelView(power: model, quit: {}).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            let settled = host.fittingSize
            host.frame = NSRect(origin: .zero, size: settled)
            window.setContentSize(settled)
            host.layoutSubtreeIfNeeded(); host.display()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "\(dark ? "dark" : "light")-\(variant).png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                print("Rendered \(name) \(settled)")
            }
        }
    }
}

@MainActor func renderSetupPreviews(_ directory: String) {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
        for step in SetupStep.allCases {
            let model = PowerController(monitor: false)
            let setup = SetupController(power: model, preview: true)
            setup.step = step; setup.ssid = "My iPhone"
            let host = NSHostingView(rootView: SetupView(setup: setup, power: model).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded(); host.display()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "\(dark ? "dark" : "light")-setup-\(step).png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                print("Rendered \(name)")
            }
        }
    }
}

@MainActor func captureSessionForUpdate(_ pid: Int) -> Bool {
    // Newer versions publish exact timers. Only this first migration needs the public IOKit fallback.
    if let data = try? Data(contentsOf: PowerController.runtimeURL),
       let state = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data),
       state.sourcePID == pid, state.bootEpoch == PowerController.bootEpoch {
        return true
    }
    var info: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&info) == kIOReturnSuccess,
          let all = info?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
    let owned = all[NSNumber(value: pid)] ?? []
    let coffee = owned.first { ($0["AssertType"] as? String) == kIOPMAssertionTypePreventUserIdleSystemSleep }
    let prefs = UserDefaults.standard
    let minutes = prefs.object(forKey: "coffeeMinutes") == nil ? 60 : prefs.integer(forKey: "coffeeMinutes")
    let started = coffee?["AssertStartWhen"] as? Date
    if coffee != nil && minutes > 0 && started == nil { return false }
    let text = (try? String(contentsOfFile: "/var/run/lidawake.state", encoding: .utf8)) ?? ""
    let lid = LidState.parse(text)
    let snapshot = RuntimeSnapshot(sourcePID: pid, bootEpoch: PowerController.bootEpoch, coffeeOn: coffee != nil,
        coffeeExpiry: minutes == 0 ? nil : started?.addingTimeInterval(Double(minutes * 60)).timeIntervalSince1970,
        coffeeStarted: started?.timeIntervalSince1970, coffeeLinkedToLid: false, coffeeSessionMinutes: minutes,
        ownedLidExpiry: lid?.expiry.timeIntervalSince1970,
        screenOn: owned.contains { ($0["AssertType"] as? String) == kIOPMAssertionTypePreventUserIdleDisplaySleep })
    do {
        try JSONEncoder().encode(snapshot).write(to: PowerController.runtimeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: PowerController.runtimeURL.path)
        return true
    } catch { return false }
}

@MainActor func runMain() {
let app = NSApplication.shared
if CommandLine.arguments.contains("--keychain-self-test") {
    let account = "Awake fixture \(UUID().uuidString)"
    defer { HotspotKeychain.removeFixture(account) }
    do { try HotspotKeychain.save("Awake-fixture-only", for: account) }
    catch { print("FAIL: keychain test write \(error)"); exit(1) }
    precondition(HotspotKeychain.password(for: account) == "Awake-fixture-only")
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["--keychain-test-read", account]
    try! child.run(); child.waitUntilExit()
    guard child.terminationStatus == 0 else { print("FAIL: background keychain read"); exit(1) }
    print("PASS: keychain write/read and same-app background credential access; fixture removed")
} else if let i = CommandLine.arguments.firstIndex(of: "--keychain-test-read"), CommandLine.arguments.count > i + 1 {
    guard HotspotKeychain.password(for: CommandLine.arguments[i + 1]) == "Awake-fixture-only" else { exit(1) }
} else if CommandLine.arguments.contains("--hotspot-password") {
    if let config = HotspotSettings.load(), config.usesKeychain, let password = HotspotKeychain.password(for: config.ssid) { print(password) }
    else { exit(1) }
} else if CommandLine.arguments.contains("--show-existing") {
    var info: [String: Any] = ["settings": CommandLine.arguments.contains("--settings"), "setup": CommandLine.arguments.contains("--setup")]
    if let i = CommandLine.arguments.firstIndex(of: "--capture-panel"), CommandLine.arguments.count > i + 1 { info["capturePath"] = CommandLine.arguments[i + 1] }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.paul.awake.show-panel"), object: nil, userInfo: info, deliverImmediately: true)
    print("Panel requested")
} else if CommandLine.arguments.contains("--capture-session"), let i = CommandLine.arguments.firstIndex(of: "--capture-session"), CommandLine.arguments.count > i + 1, let pid = Int(CommandLine.arguments[i + 1]) {
    let success = captureSessionForUpdate(pid)
    print(success ? "Session captured for update" : "Cannot capture the active session; existing app preserved")
    exit(success ? 0 : 1)
} else if CommandLine.arguments.contains("--render-preview"), let i = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > i + 1 {
    renderPreviews(CommandLine.arguments[i + 1])
} else if CommandLine.arguments.contains("--render-setup"), let i = CommandLine.arguments.firstIndex(of: "--render-setup"), CommandLine.arguments.count > i + 1 {
    renderSetupPreviews(CommandLine.arguments[i + 1])
} else if CommandLine.arguments.contains("--integration-test") {
    Task { @MainActor in
        let model = PowerController(monitor: false)
        await model.refresh(checkWatchdog: true)
        guard !model.sleepDisabled, model.lid == nil else { print("SKIP: existing lidawake session preserved"); exit(2) }
        model.lidMinutes = 30
        await model.setLid(enabled: true)
        let started = model.lid != nil && model.lidEffective && model.error == nil
        let state = try? String(contentsOfFile: "/var/run/lidawake.state", encoding: .utf8)
        let result = await model.runner.run("/usr/bin/pmset", ["-g"])
        print("Lid enabled: \(started), state file: \(state != nil), pmset:\n\(result.output)")
        let cleaned = await model.prepareToQuit()
        print("Lid released on quit: \(cleaned && !model.sleepDisabled && model.lid == nil)")
        guard started && cleaned && !model.sleepDisabled && model.lid == nil else { exit(1) }
        print("PASS: real lidawake enable, state verification, ownership, quit cleanup")
        exit(0)
    }
    app.run()
} else if CommandLine.arguments.contains("--self-test") {
    let model = PowerController(monitor: false)
    let wizardFixture = SetupController(power: model, preview: true)
    wizardFixture.ssid = "My iPhone"; wizardFixture.password = "test-password"
    wizardFixture.step = .done; wizardFixture.goBack(); precondition(wizardFixture.step == .hotspot)
    wizardFixture.goBack(); precondition(wizardFixture.step == .permission)
    wizardFixture.goBack(); precondition(wizardFixture.step == .welcome)
    wizardFixture.goBack(); precondition(wizardFixture.step == .welcome)
    precondition(wizardFixture.ssid == "My iPhone" && wizardFixture.password == "test-password")
    wizardFixture.step = .hotspot; wizardFixture.busy = true; wizardFixture.goBack()
    precondition(wizardFixture.step == .hotspot)
    precondition(HotspotSettings.validationError(ssid: "My iPhone", password: "") == nil)
    precondition(HotspotSettings.validationError(ssid: "", password: "") != nil)
    precondition(HotspotSettings.validationError(ssid: String(repeating: "a", count: 33), password: "") != nil)
    precondition(HotspotSettings.validationError(ssid: "My iPhone", password: "short") != nil)
    precondition(HotspotSettings.validationError(ssid: "My iPhone", password: "safe-test-password") == nil)
    precondition(HotspotSettings.legacyValue("HOTSPOT_SSID", in: "HOTSPOT_SSID=\"My \\" + "\"iPhone\\\"\"") == "My \"iPhone\"")
    precondition(AdministratorInstaller.shellQuote("Paul's Mac") == "'Paul'\\''s Mac'")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("awake-setup-test-\(UUID().uuidString)/hotspot.json")
    try! HotspotSettings(ssid: "My iPhone", usesKeychain: true).save(to: fixture)
    let decoded = try! JSONDecoder().decode(HotspotSettings.self, from: Data(contentsOf: fixture))
    precondition(decoded.ssid == "My iPhone" && decoded.usesKeychain)
    let permissions = try! FileManager.default.attributesOfItem(atPath: fixture.path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue == 0o600)
    try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
    precondition(LidState.parse("expiry=1\nfloor=30\nscope=-a") != nil)
    precondition(LidState.parse("expiry=nan\nfloor=30\nscope=-a") == nil)
    precondition(LidState.parse("expiry=1\nfloor=101\nscope=-a") == nil)
    precondition(LidState.parse("expiry=1\nfloor=30\nscope=bad") == nil)
    precondition(PowerController.parseCustomMinutes("15", kind: .lid) == 15)
    precondition(PowerController.parseCustomMinutes("480", kind: .lid) == 480)
    precondition(PowerController.parseCustomMinutes("481", kind: .lid) == nil)
    precondition(PowerController.parseCustomMinutes("0", kind: .coffee) == nil)
    precondition(PowerController.parseCustomMinutes("abc", kind: .coffee) == nil)
    precondition(PowerController.parseCustomMinutes("1.5", kind: .coffee) == nil)
    model.beginCustomDuration(.coffee); model.durationDraft = "75"
    precondition(model.applyCustomDuration() && model.coffeeMinutes == 75 && model.coffeeCustomSelected)
    model.beginCustomDuration(.lid); model.durationDraft = "45"
    precondition(model.applyCustomDuration() && model.lidMinutes == 45 && model.lidCustomSelected)
    model.selectPreset(45, kind: .lid); precondition(!model.lidCustomSelected && model.lidMinutes == 45)
    model.selectPreset(0, kind: .coffee); precondition(!model.coffeeCustomSelected && model.coffeeMinutes == 0)
    model.startCoffee(secondsOverride: 2)
    precondition(model.coffeeOn && model.coffeeExpiry != nil && model.error == nil)
    model.updateScreen(true)
    precondition(model.coffeeOn && model.screenOn && model.error == nil)
    model.stopCoffee(); precondition(!model.coffeeOn)
    model.startCoffee(secondsOverride: -1); model.tick(); precondition(!model.coffeeOn)
    // Enable the preference BEFORE lidawake, then simulate its successful start.
    model.setStopCoffeeWithLid(true)
    model.setAutoCoffeeWithLid(true)
    precondition(!model.coffeeOn)
    model.lid = LidState(expiry: Date().addingTimeInterval(15 * 60), floor: 30, scope: "-a")
    model.sleepDisabled = true
    model.synchronizeLinkedCoffee()
    precondition(model.coffeeOn && model.coffeeLinkedToLid && model.coffeeExpiry == model.lid?.expiry)
    model.toggleCoffee(); model.synchronizeLinkedCoffee(); precondition(!model.coffeeOn)
    model.setAutoCoffeeWithLid(true); precondition(model.coffeeOn && model.coffeeLinkedToLid)
    model.setAutoCoffeeWithLid(false); precondition(!model.coffeeOn && model.lid != nil)
    model.setAutoCoffeeWithLid(true); model.lid = nil; model.sleepDisabled = false
    model.synchronizeLinkedCoffee(); precondition(!model.coffeeOn)
    model.setAutoCoffeeWithLid(false)
    // With automatic shutdown unchecked, both early off and expiry keep coffee awake indefinitely.
    model.setStopCoffeeWithLid(false); model.setAutoCoffeeWithLid(true)
    model.lid = LidState(expiry: Date().addingTimeInterval(15 * 60), floor: 30, scope: "-a"); model.sleepDisabled = true
    model.synchronizeLinkedCoffee()
    precondition(model.coffeeOn && model.coffeeLinkedToLid && model.coffeeExpiry == nil && model.coffeeSessionMinutes == 0)
    model.setStopCoffeeWithLid(true); precondition(model.coffeeExpiry == model.lid?.expiry)
    model.setStopCoffeeWithLid(false); precondition(model.coffeeExpiry == nil)
    model.lid = nil; model.sleepDisabled = false; model.synchronizeLinkedCoffee()
    precondition(model.coffeeOn && !model.coffeeLinkedToLid && model.coffeeExpiry == nil)
    model.stopCoffee()
    model.lid = LidState(expiry: Date().addingTimeInterval(1), floor: 30, scope: "-a"); model.sleepDisabled = true
    model.synchronizeLinkedCoffee()
    model.lid = LidState(expiry: Date().addingTimeInterval(-1), floor: 30, scope: "-a")
    model.synchronizeLinkedCoffee(); model.tick()
    precondition(model.coffeeOn && !model.coffeeLinkedToLid && model.coffeeExpiry == nil)
    model.stopCoffee(); model.lid = nil; model.sleepDisabled = false
    model.setAutoCoffeeWithLid(false); model.setStopCoffeeWithLid(true)
    let controller = NSHostingController(rootView: PanelView(power: model, quit: {}))
    controller.sizingOptions = [.preferredContentSize]
    let size = controller.view.fittingSize
    precondition(size.width == 356 && size.height > 400 && size.height < 700)
    let settingsHeight = PanelView(power: model, quit: {}).measuredSettingsHeight()
    precondition(settingsHeight > 200)
    model.settingsExpandedHeight = settingsHeight; model.settingsOpen = true; model.settingsReveal = 1
    let expanded = NSHostingView(rootView: PanelView(power: model, quit: {})).fittingSize
    precondition(abs(expanded.height - size.height - settingsHeight) < 1)
    print("PASS: state parsing, real power assertions, display toggle, release, timer expiration, popover layout \(size)")
} else {
    let allowedFlags: Set<String> = ["--show-panel", "--motion-review", "--motion-playback", "--handoff", "--setup", "--restore-login"]
    if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") && !allowedFlags.contains($0) }) {
        fputs("Unknown option: \(unknown)\n", stderr)
        exit(1)
    }
    if !CommandLine.arguments.contains("--handoff"),
       NSRunningApplication.runningApplications(withBundleIdentifier: "io.paul.awake").contains(where: { $0.processIdentifier != getpid() }) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.paul.awake.show-panel"), object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

}
MainActor.assumeIsolated { runMain() }
