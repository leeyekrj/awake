import AppKit
import SwiftUI
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

struct CommandResult { let status: Int32; let output: String }
actor CommandRunner {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch { return CommandResult(status: -1, output: error.localizedDescription) }
    }
}

struct LidState: Equatable {
    let expiry: Date
    let floor: Int
    let scope: String
    static func parse(_ text: String) -> LidState? {
        let pairs = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let p = line.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }
        let values = Dictionary(pairs, uniquingKeysWith: { _, new in new })
        guard let epoch = Double(values["expiry"] ?? ""), epoch.isFinite, epoch > 0,
              let floor = Int(values["floor"] ?? ""), (1...100).contains(floor),
              let scope = values["scope"], ["-a", "-b"].contains(scope) else { return nil }
        return LidState(expiry: Date(timeIntervalSince1970: epoch), floor: floor, scope: scope)
    }
}

struct RuntimeSnapshot: Codable {
    let sourcePID: Int
    let bootEpoch: Double
    let coffeeOn: Bool
    let coffeeExpiry: Double?
    let coffeeStarted: Double?
    let coffeeLinkedToLid: Bool
    let coffeeSessionMinutes: Int
    let ownedLidExpiry: Double?
    let screenOn: Bool
    var loginEnabled: Bool? = nil
}

enum DurationKind { case coffee, lid }

// A second passing must not invalidate the settings and every native control.
@MainActor final class DisplayClock: ObservableObject {
    @Published var now = Date()
    func countdown(_ expiry: Date?) -> String {
        guard let expiry else { return "∞" }
        let seconds = max(0, Int(ceil(expiry.timeIntervalSince(now))))
        if seconds >= 3600 { return "\(seconds / 3600):\(String(format: "%02d", seconds % 3600 / 60)):\(String(format: "%02d", seconds % 60))" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    func progress(_ expiry: Date?, minutes: Int) -> Double {
        guard let expiry else { return 1 }
        return min(1, max(0, expiry.timeIntervalSince(now) / Double(max(1, minutes) * 60)))
    }
}

@MainActor final class PowerController: ObservableObject {
    @Published var coffeeOn = false
    @Published var coffeeLinkedToLid = false
    @Published var coffeeSessionMinutes = 60
    @Published var hotspotEnabled = true { didSet { defaults.set(hotspotEnabled, forKey: "hotspotEnabled"); if live { writeHotspotSwitch() } } }
    @Published var netguardAlways = false
    @Published var autoCoffeeWithLid = false { didSet { defaults.set(autoCoffeeWithLid, forKey: "autoCoffeeWithLid") } }
    @Published var stopCoffeeWithLid = true { didSet { defaults.set(stopCoffeeWithLid, forKey: "stopCoffeeWithLid") } }
    @Published var hotspotWarning: String?
    @Published var coffeeExpiry: Date?
    @Published var coffeeStarted: Date?
    @Published var coffeeMinutes = 60 { didSet { defaults.set(coffeeMinutes, forKey: "coffeeMinutes") } }
    @Published var screenOn = false { didSet { defaults.set(screenOn, forKey: "screenOn") } }
    @Published var lidMinutes = 60 { didSet { defaults.set(lidMinutes, forKey: "lidMinutes") } }
    @Published var coffeeCustomSelected = false { didSet { defaults.set(coffeeCustomSelected, forKey: "coffeeCustomSelected") } }
    @Published var lidCustomSelected = false { didSet { defaults.set(lidCustomSelected, forKey: "lidCustomSelected") } }
    @Published var coffeeCustomMinutes = 90 { didSet { defaults.set(coffeeCustomMinutes, forKey: "coffeeCustomMinutes") } }
    @Published var lidCustomMinutes = 45 { didSet { defaults.set(lidCustomMinutes, forKey: "lidCustomMinutes") } }
    @Published var durationEditor: DurationKind?
    @Published var durationDraft = ""
    @Published var durationError: String?
    @Published var floor = 30 { didSet { defaults.set(floor, forKey: "floor") } }
    @Published var lid: LidState?
    @Published var lidEffective = false
    @Published var sleepDisabled = false
    @Published var watchdogReady = false
    @Published var helperAuthorized = false
    @Published var battery = 100
    @Published var onAC = false
    @Published var busy = false
    @Published var error: String?
    let displayClock = DisplayClock()
    var now: Date {
        get { displayClock.now }
        set { displayClock.now = newValue }
    }
    var clockVisible = false
    @Published var settingsOpen = false
    @Published var settingsReveal = 0.0
    @Published var settingsExpandedHeight = 135.0
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private let live: Bool
    let defaults: UserDefaults
    let runner = CommandRunner()
    private var assertions: [IOPMAssertionID] = []
    private var timer: Timer?
    private var ticks = 0
    private var refreshing = false
    private var ownedLidExpiry: Date?
    private var manualCoffeeOverride: Date?
    var stateChanged: (() -> Void)?
    var restoreLoginOnLaunch = false
    var anyOn: Bool { coffeeOn || lid != nil || sleepDisabled }
    static let bundledHelperPath = "/Library/Application Support/Awake/lidawake"
    var helperPath: String { FileManager.default.isExecutableFile(atPath: Self.bundledHelperPath) ? Self.bundledHelperPath : "/usr/local/bin/lidawake" }
    var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }
    var nearestExpiry: Date? { [coffeeExpiry, lid?.expiry].compactMap { $0 }.min() }

    init(monitor: Bool = true) {
        live = monitor
        defaults = monitor ? UserDefaults.standard : UserDefaults(suiteName: "io.paul.awake.preview")!
        if defaults.object(forKey: "coffeeMinutes") != nil { coffeeMinutes = defaults.integer(forKey: "coffeeMinutes") }
        if coffeeMinutes < 0 || coffeeMinutes > Int.max / 60 { coffeeMinutes = 60 }
        if defaults.object(forKey: "lidMinutes") != nil { lidMinutes = defaults.integer(forKey: "lidMinutes") }
        if !(1...480).contains(lidMinutes) { lidMinutes = 60 }
        coffeeCustomSelected = coffeeMinutes != 0 && (defaults.bool(forKey: "coffeeCustomSelected") || ![60,120,240].contains(coffeeMinutes))
        lidCustomSelected = defaults.bool(forKey: "lidCustomSelected") || ![15,30,45,60].contains(lidMinutes)
        let savedCoffee = defaults.integer(forKey: "coffeeCustomMinutes")
        let savedLid = defaults.integer(forKey: "lidCustomMinutes")
        if savedCoffee > 0 && savedCoffee <= Int.max / 60 { coffeeCustomMinutes = savedCoffee }
        if (1...480).contains(savedLid) { lidCustomMinutes = savedLid }
        if coffeeCustomSelected { coffeeCustomMinutes = coffeeMinutes }
        if lidCustomSelected { lidCustomMinutes = lidMinutes }
        if defaults.object(forKey: "floor") != nil { floor = defaults.integer(forKey: "floor") }
        if ![20,30,40].contains(floor) { floor = 30 }
        screenOn = defaults.bool(forKey: "screenOn")
        if defaults.object(forKey: "hotspotEnabled") != nil { hotspotEnabled = defaults.bool(forKey: "hotspotEnabled") }
        netguardAlways = (try? String(contentsOf: netguardAlwaysURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        autoCoffeeWithLid = defaults.bool(forKey: "autoCoffeeWithLid")
        if defaults.object(forKey: "stopCoffeeWithLid") != nil { stopCoffeeWithLid = defaults.bool(forKey: "stopCoffeeWithLid") }
        if monitor {
            let restored = restoreRuntimeForUpdate()
            if restored {
                writeRuntimeSnapshot()
                writeHotspotSwitch()
                Task { await configureEmbeddedNetguard() }
            } else { error = "기존 세션을 이어받지 못했어요. 기존 앱은 유지됩니다." }
            Task { await refresh(checkWatchdog: true) }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }
    static func parseCustomMinutes(_ text: String, kind: DurationKind) -> Int? {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              minutes > 0, minutes <= Int.max / 60 else { return nil }
        if kind == .lid && minutes > 480 { return nil }
        return minutes
    }
    func durationLocked(_ kind: DurationKind) -> Bool {
        kind == .coffee ? coffeeOn : (lid != nil || sleepDisabled || busy)
    }
    func selectPreset(_ minutes: Int, kind: DurationKind) {
        guard !durationLocked(kind) else { return }
        if kind == .coffee {
            guard [0,60,120,240].contains(minutes) else { return }
            coffeeMinutes = minutes; coffeeCustomSelected = false
        } else {
            guard [15,30,45,60].contains(minutes) else { return }
            lidMinutes = minutes; lidCustomSelected = false
        }
        durationEditor = nil; durationError = nil
    }
    func beginCustomDuration(_ kind: DurationKind) {
        guard !durationLocked(kind) else { return }
        durationDraft = String(kind == .coffee ? coffeeCustomMinutes : lidCustomMinutes)
        durationError = nil; durationEditor = kind
    }
    @discardableResult func applyCustomDuration() -> Bool {
        guard let kind = durationEditor, !durationLocked(kind) else { return false }
        guard let minutes = Self.parseCustomMinutes(durationDraft, kind: kind) else {
            durationError = kind == .lid ? "1~480분 사이의 정수를 입력해 주세요." : "1분 이상의 정수를 입력해 주세요."
            return false
        }
        if kind == .coffee {
            coffeeMinutes = minutes; coffeeCustomMinutes = minutes; coffeeCustomSelected = true
        } else {
            lidMinutes = minutes; lidCustomMinutes = minutes; lidCustomSelected = true
        }
        durationEditor = nil; durationError = nil
        return true
    }
    func tick() {
        let current = Date()
        if clockVisible { now = current }
        ticks += 1
        if coffeeOn, let expiry = coffeeExpiry, current >= expiry {
            if coffeeLinkedToLid { finishLinkedCoffee() } else { stopCoffee() }
        }
        // The root watchdog owns expiration, including after the app crashes.
        if live && ticks % (anyOn ? 5 : 30) == 0 { Task { await refresh(checkWatchdog: ticks % 60 == 0) } }
        stateChanged?()
    }
    func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let connected = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        if onAC != connected { onAC = connected }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            if let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                let percentage = current * 100 / max
                if battery != percentage { battery = percentage }
                break
            }
        }
    }
    func refresh(checkWatchdog: Bool = false) async {
        if refreshing {
            while refreshing { try? await Task.sleep(nanoseconds: 50_000_000) }
            if !checkWatchdog { return }
        }
        refreshing = true
        defer { refreshing = false; stateChanged?() }
        readBattery()
        if checkWatchdog {
            var ready = false
            let labels = helperPath == Self.bundledHelperPath ? ["io.paul.awake.lidawake"] : ["io.theplato.paul.lidawake", "io.theplato.lidawake"]
            for label in labels {
                let result = await runner.run("/bin/launchctl", ["print", "system/\(label)"])
                if result.status == 0 && result.output.contains("lidawake-watchdog") { ready = true; break }
            }
            if watchdogReady != ready { watchdogReady = ready }
            let permissions = await runner.run("/usr/bin/sudo", ["-n", "-l"])
            let authorized = permissions.status == 0 && permissions.output.components(separatedBy: .newlines).contains {
                let line = $0.replacingOccurrences(of: "\\ ", with: " ")
                return line.contains("NOPASSWD:") && (line.contains(helperPath) || line.contains("NOPASSWD: ALL"))
            }
            if helperAuthorized != authorized { helperAuthorized = authorized }
        }
        let r = await runner.run("/usr/bin/pmset", ["-g"])
        guard r.status == 0 else { error = "전원 상태를 읽지 못했어요. 다시 시도해 주세요."; return }
        let disabled = r.output.split(separator: "\n").contains {
            let parts = $0.split(whereSeparator: { $0.isWhitespace })
            return parts.count >= 2 && ["SleepDisabled", "disablesleep"].contains(String(parts[0])) && parts[1] == "1"
        }
        if sleepDisabled != disabled { sleepDisabled = disabled }
        let text = (try? String(contentsOfFile: "/var/run/lidawake.state", encoding: .utf8)) ?? ""
        let parsed = LidState.parse(text)
        // pmset is the actual state. A leftover state file alone does not mean awake.
        let currentLid = sleepDisabled ? parsed : nil
        if lid != currentLid { lid = currentLid }
        let effective = sleepDisabled && (parsed?.scope == "-a" || !onAC)
        if lidEffective != effective { lidEffective = effective }
        synchronizeLinkedCoffee()
    }
    func toggleCoffee() {
        if autoCoffeeWithLid { manualCoffeeOverride = lid?.expiry }
        coffeeOn ? stopCoffee() : startCoffee()
    }
    func startCoffee(secondsOverride: TimeInterval? = nil, linkedToLid: Bool = false) {
        let types = [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep] + (screenOn ? [kIOPMAssertionTypePreventUserIdleDisplaySleep] : [])
        var created: [IOPMAssertionID] = []
        for type in types {
            var id: IOPMAssertionID = 0
            let code = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Awake · 잠자기 방지" as CFString, &id)
            guard code == kIOReturnSuccess else {
                created.forEach { IOPMAssertionRelease($0) }
                error = "잠자기 방지를 켜지 못했어요 (\(code))."; return
            }
            created.append(id)
        }
        assertions.forEach { IOPMAssertionRelease($0) }; assertions = created
        now = Date()
        coffeeStarted = now
        coffeeExpiry = secondsOverride.map { now.addingTimeInterval($0) } ?? (coffeeMinutes == 0 ? nil : now.addingTimeInterval(Double(coffeeMinutes * 60)))
        coffeeLinkedToLid = linkedToLid
        coffeeSessionMinutes = secondsOverride.map { max(1, Int(ceil($0 / 60))) } ?? coffeeMinutes
        coffeeOn = true; error = nil; writeRuntimeSnapshot(); stateChanged?()
    }
    func stopCoffee() {
        assertions.forEach { IOPMAssertionRelease($0) }; assertions.removeAll()
        coffeeOn = false; coffeeExpiry = nil; coffeeStarted = nil; coffeeLinkedToLid = false
        writeRuntimeSnapshot(); stateChanged?()
    }
    func updateScreen(_ value: Bool) {
        screenOn = value
        if coffeeOn {
            let expiry = coffeeExpiry, start = coffeeStarted, linked = coffeeLinkedToLid, minutes = coffeeSessionMinutes
            startCoffee(linkedToLid: linked); coffeeExpiry = expiry; coffeeStarted = start; coffeeSessionMinutes = minutes
            writeRuntimeSnapshot()
        }
    }
    func toggleLid() { Task { await setLid(enabled: lid == nil && !sleepDisabled) } }
    func setLid(enabled: Bool) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false; stateChanged?() }
        if enabled {
            await refresh(checkWatchdog: true)
            guard helperInstalled && watchdogReady && helperAuthorized else {
                error = "설정의 ‘설치·핫스팟 설정’에서 lidawake 설치를 완료해 주세요."; return
            }
            guard onAC || battery >= floor else {
                error = "배터리가 \(battery)%라 켤 수 없어요. 충전하거나 보호 기준을 낮춰 주세요."; return
            }
        }
        let args = enabled ? ["-n", helperPath, String(lidMinutes), String(floor), "-a"] : ["-n", helperPath, "off"]
        let r = await runner.run("/usr/bin/sudo", args)
        await refresh()
        guard r.status == 0 else {
            error = r.output.contains("password") ? "설정의 ‘설치·핫스팟 설정’에서 실행 권한을 승인해 주세요." : "lidawake 실행 실패: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))"
            return
        }
        if enabled {
            guard lid != nil && lidEffective else { error = "명령은 실행됐지만 켜진 상태를 확인하지 못했어요."; return }
            ownedLidExpiry = lid?.expiry
        } else {
            if sleepDisabled { error = "아직 잠자기 방지가 켜져 있어요. 전원 상태를 확인해 주세요." }
            ownedLidExpiry = nil
        }
        synchronizeLinkedCoffee()
        writeRuntimeSnapshot()
    }
    func setAutoCoffeeWithLid(_ enabled: Bool) {
        autoCoffeeWithLid = enabled
        manualCoffeeOverride = nil
        if !enabled { finishLinkedCoffee() }
        synchronizeLinkedCoffee()
        writeRuntimeSnapshot()
    }
    func setStopCoffeeWithLid(_ enabled: Bool) {
        stopCoffeeWithLid = enabled
        synchronizeLinkedCoffee()
        writeRuntimeSnapshot()
    }
    private func finishLinkedCoffee() {
        guard coffeeLinkedToLid else { return }
        if stopCoffeeWithLid { stopCoffee() }
        else {
            // Keep the existing power assertions; only release the link and timer.
            coffeeLinkedToLid = false
            coffeeExpiry = nil
            coffeeSessionMinutes = 0
            writeRuntimeSnapshot(); stateChanged?()
        }
    }
    func synchronizeLinkedCoffee() {
        guard let state = lid, sleepDisabled, state.expiry > Date() else {
            finishLinkedCoffee()
            return
        }
        guard autoCoffeeWithLid, manualCoffeeOverride != state.expiry else { return }
        if !coffeeLinkedToLid {
            startCoffee(secondsOverride: state.expiry.timeIntervalSinceNow, linkedToLid: true)
        }
        let expiry = stopCoffeeWithLid ? state.expiry : nil
        if coffeeOn && (coffeeExpiry != expiry || (expiry == nil && coffeeSessionMinutes != 0)) {
            coffeeExpiry = expiry
            coffeeSessionMinutes = stopCoffeeWithLid ? max(1, Int(ceil(state.expiry.timeIntervalSinceNow / 60))) : 0
            writeRuntimeSnapshot(); stateChanged?()
        }
    }
    static var runtimeURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/awake-runtime-session.json") }
    static var handoffAckURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/awake-session-handoff-ack.json") }
    static var bootEpoch: Double {
        var boot = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Double(boot.tv_sec)
    }
    func writeRuntimeSnapshot() {
        guard live else { return }
        let state = RuntimeSnapshot(sourcePID: Int(getpid()), bootEpoch: Self.bootEpoch, coffeeOn: coffeeOn,
            coffeeExpiry: coffeeExpiry?.timeIntervalSince1970, coffeeStarted: coffeeStarted?.timeIntervalSince1970,
            coffeeLinkedToLid: coffeeLinkedToLid, coffeeSessionMinutes: coffeeSessionMinutes,
            ownedLidExpiry: ownedLidExpiry?.timeIntervalSince1970, screenOn: screenOn, loginEnabled: loginEnabled)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.runtimeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.runtimeURL.path)
        }
        defaults.synchronize()
    }
    func restoreRuntimeForUpdate() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--handoff"), CommandLine.arguments.count > index + 1,
              let oldPID = Int(CommandLine.arguments[index + 1]) else { return true }
        var ready = false
        if let data = try? Data(contentsOf: Self.runtimeURL), let state = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data),
           state.sourcePID == oldPID, abs(state.bootEpoch - Self.bootEpoch) < 5 {
            restoreLoginOnLaunch = state.loginEnabled == true
            ownedLidExpiry = state.ownedLidExpiry.map { Date(timeIntervalSince1970: $0) }
            screenOn = state.screenOn
            if state.coffeeOn && (state.coffeeExpiry == nil || state.coffeeExpiry! > Date().timeIntervalSince1970) {
                let seconds = state.coffeeExpiry.map { $0 - Date().timeIntervalSince1970 }
                startCoffee(secondsOverride: seconds, linkedToLid: state.coffeeLinkedToLid)
                if coffeeOn {
                    coffeeExpiry = state.coffeeExpiry.map { Date(timeIntervalSince1970: $0) }
                    coffeeStarted = state.coffeeStarted.map { Date(timeIntervalSince1970: $0) }
                    coffeeSessionMinutes = state.coffeeSessionMinutes
                }
                ready = coffeeOn
            } else { ready = true }
        }
        let ack: [String: Any] = ["sourcePID": oldPID, "newPID": Int(getpid()), "ready": ready]
        if let data = try? JSONSerialization.data(withJSONObject: ack) { try? data.write(to: Self.handoffAckURL, options: .atomic) }
        return ready
    }
    private var hotspotSwitchURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Awake/netguard-enabled") }
    func writeHotspotSwitch() {
        try? FileManager.default.createDirectory(at: hotspotSwitchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (hotspotEnabled ? "1\n" : "0\n").write(to: hotspotSwitchURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hotspotSwitchURL.path)
    }
    func setHotspotEnabled(_ enabled: Bool) {
        hotspotEnabled = enabled
        if live {
            if !enabled { try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/lidawake-netguard.state")) }
            Task { await configureEmbeddedNetguard() }
        }
    }
    // The netguard script reads this file directly: 1 = watch even when lidawake is off.
    private var netguardAlwaysURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Awake/netguard-always") }
    func setNetguardAlways(_ enabled: Bool) {
        netguardAlways = enabled
        guard live else { return }
        try? FileManager.default.createDirectory(at: netguardAlwaysURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (enabled ? "1\n" : "0\n").write(to: netguardAlwaysURL, atomically: true, encoding: .utf8)
    }
    func configureEmbeddedNetguard() async {
        guard live else { return }
        // A fresh Mac starts recovery only after its own hotspot has been configured.
        guard HotspotSettings.load() != nil else { hotspotWarning = nil; return }
        HotspotKeychain.migrateIfNeeded()
        guard let script = Bundle.main.url(forResource: "lidawake-netguard", withExtension: nil) else {
            hotspotWarning = "핫스팟 연결 스크립트를 찾지 못했어요."; return
        }
        let label = "io.theplato.paul.lidawake-netguard"
        let domain = "gui/\(getuid())"
        let plist = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let payload: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/bash", script.path, "run"],
            "RunAtLoad": true, "StartInterval": 15,
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/lidawake-netguard.err.log"]
        for _ in 0..<60 {
            let existing = await runner.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
            if existing.status == 0 && existing.output.components(separatedBy: .newlines).contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == script.path
            }) { hotspotWarning = nil; return }
            if existing.status == 0 && existing.output.contains("state = running") {
                try? await Task.sleep(nanoseconds: 500_000_000); continue
            }
            do {
                try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                let backup = plist.appendingPathExtension("before-awake")
                if FileManager.default.fileExists(atPath: plist.path) && !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: plist, to: backup)
                }
                let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
                if existing.status == 0 { _ = await runner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"]) }
                try data.write(to: plist, options: .atomic)
                let result = await runner.run("/bin/launchctl", ["bootstrap", domain, plist.path])
                hotspotWarning = result.status == 0 ? nil : "핫스팟 감시자를 등록하지 못했어요. 앱을 다시 실행해 주세요."
            } catch { hotspotWarning = "핫스팟 설정을 저장하지 못했어요." }
            return
        }
        hotspotWarning = "기존 네트워크 복구가 끝나면 앱을 다시 실행해 주세요."
    }
    func toggleLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "로그인 시 실행 설정을 바꾸지 못했어요: \(error.localizedDescription)" }
    }
    func prepareToQuit() async -> Bool {
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        await refresh()
        stopCoffee()
        if let owned = ownedLidExpiry, let current = lid, current.expiry == owned {
            await setLid(enabled: false)
            if sleepDisabled { return false }
        }
        return true
    }
    func countdown(_ expiry: Date?) -> String {
        displayClock.countdown(expiry)
    }
    func progress(_ expiry: Date?, minutes: Int) -> Double {
        displayClock.progress(expiry, minutes: minutes)
    }
}
