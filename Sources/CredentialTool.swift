// Keep this executable separate from the frequently rebuilt menu app.
// Its bytes and path are preserved across app updates, including ad-hoc builds.
import Foundation
import Security

// LAContext.interactionNotAllowed alone doesn't suppress file-keychain ACL UI.
// This process must NEVER wait for a password dialog, including during writes.
SecKeychainSetUserInteractionAllowed(false)
let args = CommandLine.arguments
guard args.count == 3, ["get", "put", "delete"].contains(args[1]),
      !args[2].isEmpty, args[2].utf8.count <= 128 else { exit(64) }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.paul.awake.hotspot.credentials-v2",
    // Swift Process arguments can arrive decomposed while plutil emits composed
    // Korean. File-keychain account matching compares bytes, not graphemes.
    kSecAttrAccount as String: args[2].precomposedStringWithCanonicalMapping
]
var status: OSStatus
switch args[1] {
case "get":
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
        FileHandle.standardOutput.write(data)
    }
case "put":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard (8...64).contains(data.count), let password = String(data: data, encoding: .utf8),
          !password.contains(where: { $0.isNewline || $0 == "\0" }) else { exit(65) }
    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Awake hotspot · \(args[2])"
        // Default ACL trusts only this stable executable, not every application.
        status = SecItemAdd(item as CFDictionary, nil)
    }
default:
    status = SecItemDelete(query as CFDictionary)
}
if status != errSecSuccess {
    FileHandle.standardError.write(Data("Keychain status: \(status)\n".utf8))
    exit(status == errSecItemNotFound ? 2 : 1)
}
