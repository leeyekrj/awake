import AppKit
import SwiftUI
import Security

enum SetupStep: Int, CaseIterable { case welcome, permission, hotspot, done }

struct HotspotSettings: Codable, Equatable {
    var ssid: String
    var usesKeychain: Bool
    static var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Awake/hotspot.json") }
    static var legacyURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/lidawake/netguard.conf") }
    static func load() -> HotspotSettings? {
        if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Self.self, from: data) { return config }
        if let text = try? String(contentsOf: legacyURL, encoding: .utf8), let ssid = legacyValue("HOTSPOT_SSID", in: text), !ssid.isEmpty {
            return HotspotSettings(ssid: ssid, usesKeychain: false)
        }
        return nil
    }
    // Read known assignments only. Never execute an old shell configuration in the app.
    static func legacyValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + "=") else { continue }
            let raw = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("'"), raw.hasSuffix("'") { return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'") }
            if raw.hasPrefix("\""), raw.hasSuffix("\"") {
                let chars = Array(raw.dropFirst().dropLast()); var result = "", i = 0
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count, ["\\", "\"", "$", "`"].contains(chars[i + 1]) { i += 1 }
                    result.append(chars[i]); i += 1
                }
                return result
            }
            if !raw.contains(where: { $0.isWhitespace }) && !raw.contains("$") && !raw.contains("`") { return raw }
        }
        return nil
    }
    static func validationError(ssid: String, password: String) -> String? {
        if ssid.isEmpty || ssid.utf8.count > 32 || ssid.contains(where: { $0.isNewline || $0 == "\0" }) { return "핫스팟 이름을 1~32바이트로 입력해 주세요." }
        let hex = password.utf8.count == 64 && password.allSatisfy { $0.isHexDigit && $0.isASCII }
        if !password.isEmpty && (!(8...63).contains(password.utf8.count) && !hex || password.contains(where: { $0.isNewline || $0 == "\0" })) {
            return "Wi-Fi 암호는 8~63바이트로 입력해 주세요." }
        return nil
    }
    func save(to destination: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

enum HotspotKeychain {
    static var toolURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Awake/awake-credentials")
    }
    static func prepareTool() throws {
        guard let bundled = Bundle.main.url(forResource: "awake-credentials", withExtension: nil) else {
            throw NSError(domain: "AwakeCredentials", code: 1)
        }
        let fm = FileManager.default
        let data = try Data(contentsOf: bundled)
        try fm.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Do not replace an unchanged tool: keychain trusts its fixed path and code hash.
        if (try? Data(contentsOf: toolURL)) != data {
            try data.write(to: toolURL, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)
    }
    static func runTool(_ command: String, _ ssid: String, input: Data? = nil) -> (Int32, Data) {
        do { try prepareTool() } catch { return (-1, Data()) }
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = toolURL; process.arguments = [command, ssid]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        do {
            try process.run()
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch { return (-1, Data()) }
    }
    static func save(_ password: String, for ssid: String) throws {
        let (status, _) = runTool("put", ssid, input: Data(password.utf8))
        guard status == 0 else { throw NSError(domain: "AwakeCredentials", code: Int(status)) }
    }
    static func password(for ssid: String, interactive: Bool = false) -> String? {
        let (status, data) = runTool("get", ssid)
        if status == 0 { return String(data: data, encoding: .utf8) }
        // Only a user-initiated connection test may request one-time access to
        // the pre-1.1.2 item. Background recovery never uses this path.
        guard interactive, let legacy = oldPassword(for: ssid, interactive: true) else { return nil }
        do { try save(legacy, for: ssid); return legacy } catch { return nil }
    }
    private static func oldPassword(for ssid: String, interactive: Bool) -> String? {
        var previous = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(interactive)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.paul.awake.hotspot", kSecAttrAccount as String: ssid,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func removeFixture(_ ssid: String) { _ = runTool("delete", ssid) }
    static func migrateIfNeeded() {
        guard let config = HotspotSettings.load(), config.usesKeychain,
              password(for: config.ssid) == nil else { return }
        if let secret = oldPassword(for: config.ssid, interactive: false) {
            try? save(secret, for: config.ssid); return
        }
        // Older local installs already have a protected legacy configuration.
        // Use it only for the same SSID, without opening the old keychain item's UI.
        if let text = try? String(contentsOf: HotspotSettings.legacyURL, encoding: .utf8),
           HotspotSettings.legacyValue("HOTSPOT_SSID", in: text) == config.ssid,
           let secret = HotspotSettings.legacyValue("HOTSPOT_PASSWORD", in: text), !secret.isEmpty {
            try? save(secret, for: config.ssid)
        }
    }
}

actor AdministratorInstaller {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    func install(script: String, user: String) -> String? {
        let command = "/bin/bash \(Self.shellQuote(script)) \(Self.shellQuote(user))"
        return authorize(command: command)
    }
    func installApplication(source: String) -> String? {
        let destination = "/Applications/Awake.app"
        let staged = "/Applications/.Awake-install-\(UUID().uuidString).app"
        let backup = "/Applications/.Awake-backup-\(UUID().uuidString).app"
        let command = "set -e\n/usr/bin/ditto \(Self.shellQuote(source)) \(Self.shellQuote(staged))\n/usr/bin/codesign --verify --deep --strict \(Self.shellQuote(staged))\nif [ -e \(Self.shellQuote(destination)) ]; then /bin/mv \(Self.shellQuote(destination)) \(Self.shellQuote(backup)); fi\n/bin/mv \(Self.shellQuote(staged)) \(Self.shellQuote(destination))"
        return authorize(command: command)
    }
    private func authorize(command: String) -> String? {
        let code = "do shell script \(Self.appleScriptString(command)) with administrator privileges"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", code]; process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
            if String(decoding: data, as: UTF8.self).contains("(-128)") { return "설치를 취소했어요. 준비되면 다시 시도해 주세요." }
            return "설치하지 못했어요. 관리자 계정으로 승인했는지 확인하고 다시 시도해 주세요."
        } catch { return "관리자 인증 창을 열지 못했어요." }
    }
}

@MainActor final class SetupController: ObservableObject {
    @Published var step: SetupStep = .welcome
    @Published var busy = false
    @Published var error: String?
    @Published var allowPasswordless = false
    @Published var ssid = ""
    @Published var password = ""
    @Published var hotspotEnabled = true
    @Published var hasSavedPassword = false
    @Published var connectionResult: String?
    let power: PowerController
    private let administrator = AdministratorInstaller()
    private let preview: Bool
    var requestClose: (() -> Void)?
    init(power: PowerController, preview: Bool = false) {
        self.power = power; self.preview = preview
        if !preview {
            let existing = HotspotSettings.load(); ssid = existing?.ssid ?? ""
            hasSavedPassword = existing?.usesKeychain == true || !(Self.legacyPassword() ?? "").isEmpty
            hotspotEnabled = power.hotspotEnabled
            if power.defaults.bool(forKey: "setupResumePermissions") { step = .permission; power.defaults.removeObject(forKey: "setupResumePermissions") }
        }
    }
    var helperReady: Bool { power.helperInstalled && power.watchdogReady && power.helperAuthorized }
    static func legacyPassword() -> String? {
        guard let text = try? String(contentsOf: HotspotSettings.legacyURL, encoding: .utf8) else { return nil }
        return HotspotSettings.legacyValue("HOTSPOT_PASSWORD", in: text)
    }
    func begin() { Task {
        busy = true; error = nil; defer { busy = false }
        do {
            if !preview { if try await relocateIfNeeded() { return } }
            await power.refresh(checkWatchdog: true); step = .permission
        } catch { self.error = "앱을 Applications 폴더에 설치하지 못했어요. 폴더 권한을 확인해 주세요." }
    } }
    func installHelper() { Task {
        guard allowPasswordless else { return }
        busy = true; error = nil; defer { busy = false }
        guard let script = Bundle.main.path(forResource: "awake-install", ofType: "sh") else { error = "설치 파일을 찾지 못했어요. 앱을 다시 받아 주세요."; return }
        if let failure = await administrator.install(script: script, user: NSUserName()) { error = failure; return }
        await power.refresh(checkWatchdog: true)
        guard helperReady else { error = "설치된 도구를 확인하지 못했어요. 다시 시도해 주세요."; return }
        step = .hotspot
    } }
    func saveHotspot() async -> Bool {
        error = nil
        if hotspotEnabled {
            let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            if let issue = HotspotSettings.validationError(ssid: name, password: password) { error = issue; return false }
            let existing = HotspotSettings.load()
            var keychain = existing?.ssid == name && existing?.usesKeychain == true
            let legacy = existing?.ssid == name && existing?.usesKeychain == false ? Self.legacyPassword() : nil
            let secret = password.isEmpty ? (legacy ?? "") : password
            do {
                if !secret.isEmpty { try HotspotKeychain.save(secret, for: name); keychain = true }
                try HotspotSettings(ssid: name, usesKeychain: keychain).save()
                ssid = name; password = ""; hasSavedPassword = keychain
            } catch { self.error = "핫스팟 설정을 저장하지 못했어요. 키체인 접근을 허용했는지 확인해 주세요."; return false }
        }
        power.setHotspotEnabled(hotspotEnabled)
        await power.configureEmbeddedNetguard()
        if let warning = power.hotspotWarning { error = warning; return false }
        return true
    }
    func finish() { Task {
        busy = true; defer { busy = false }
        guard await saveHotspot() else { return }
        power.defaults.set(true, forKey: "setupCompleted")
        step = .done
    } }
    func later() {
        power.defaults.set(true, forKey: "setupDeferred")
        requestClose?()
    }
    func goBack() {
        guard !busy, let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        error = nil; connectionResult = nil; step = previous
    }
    func testConnection() { Task {
        busy = true; connectionResult = nil; defer { busy = false }
        guard hotspotEnabled, await saveHotspot(), let config = HotspotSettings.load() else { return }
        var args = ["-setairportnetwork", "en0", config.ssid]
        let ports = await power.runner.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = ports.output.components(separatedBy: .newlines)
        if let i = lines.firstIndex(where: { $0 == "Hardware Port: Wi-Fi" }), i + 1 < lines.count { args[1] = lines[i + 1].replacingOccurrences(of: "Device: ", with: "") }
        if config.usesKeychain {
            guard let secret = HotspotKeychain.password(for: config.ssid, interactive: true) else { error = "저장된 암호를 읽지 못했어요. 암호를 다시 입력해 주세요."; return }
            args.append(secret)
        }
        let joined = await power.runner.run("/usr/sbin/networksetup", args)
        guard joined.status == 0 && !joined.output.localizedCaseInsensitiveContains("error") && !joined.output.localizedCaseInsensitiveContains("could not") else {
            connectionResult = "연결하지 못했어요. 핫스팟 이름·암호와 휴대폰의 핫스팟 켜짐 상태를 확인해 주세요."; return
        }
        let online = await power.runner.run("/usr/bin/curl", ["-fsS", "--max-time", "8", "https://captive.apple.com/hotspot-detect.html"])
        connectionResult = online.status == 0 && online.output.contains("Success") ? "연결을 시도했고 인터넷 응답을 확인했어요." : "연결을 시도했지만 인터넷 응답이 없어요. 휴대폰의 데이터 연결을 확인해 주세요."
    } }
    private func relocateIfNeeded() async throws -> Bool {
        let destination = URL(fileURLWithPath: "/Applications/Awake.app")
        let source = Bundle.main.bundleURL
        guard source.standardizedFileURL != destination.standardizedFileURL else { return false }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
            if let failure = await administrator.installApplication(source: source.path) {
                throw NSError(domain: "AwakeSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
            }
        } else {
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".Awake-install-\(UUID().uuidString).app")
            try fm.copyItem(at: source, to: staged)
            if fm.fileExists(atPath: destination.path) {
                let backup = destination.deletingLastPathComponent().appendingPathComponent(".Awake-backup-\(UUID().uuidString).app")
                try fm.moveItem(at: destination, to: backup)
            }
            try fm.moveItem(at: staged, to: destination)
        }
        power.defaults.set(true, forKey: "setupResumePermissions"); power.writeRuntimeSnapshot()
        try? fm.removeItem(at: PowerController.handoffAckURL)
        let opened = await power.runner.run("/usr/bin/open", ["-n", "-g", destination.path, "--args", "--handoff", String(getpid()), "--setup"])
        guard opened.status == 0 else { throw NSError(domain: "AwakeSetup", code: 1) }
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: PowerController.handoffAckURL),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               ack["sourcePID"] as? Int == Int(getpid()), ack["ready"] as? Bool == true {
                exit(0) // Successor owns the session; preserve lidawake during this handoff.
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "AwakeSetup", code: 2)
    }
}
