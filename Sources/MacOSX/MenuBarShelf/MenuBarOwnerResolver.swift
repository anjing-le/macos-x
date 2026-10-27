import AppKit
import Darwin
import Security

/// Read-only process metadata. Helpers need not be registered applications,
/// and MenuBarAgent can retain an exited owner's accessibility node.
enum MenuBarOwnerResolver {
    enum Resolution {
        case identified(MenuBarOwnerIdentity)
        case exited
        case unreadable
    }
    static func isAlive(_ pid:pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid,0) == 0 { return true }
        return errno != ESRCH // Permission denial is not proof of exit.
    }
    static func resolve(_ pid:pid_t, workspaceBundle:String?) -> Resolution {
        guard isAlive(pid) else { return .exited }
        let registered = NSRunningApplication(processIdentifier:pid)?.bundleIdentifier
        var aliases = Set<String>()
        if let registered, !registered.isEmpty { aliases.insert(registered) }
        var bytes = [CChar](repeating:0,count:4096)
        if proc_pidpath(pid,&bytes,UInt32(bytes.count)) > 0 {
            var path = URL(fileURLWithPath:String(cString:bytes)).deletingLastPathComponent()
            for _ in 0..<32 {
                if ["app","xpc","appex","bundle"].contains(path.pathExtension.lowercased()),
                   let id = Bundle(url:path)?.bundleIdentifier, !id.isEmpty { aliases.insert(id) }
                let parent = path.deletingLastPathComponent()
                if parent == path { break }; path = parent
            }
        }
        // Cached workspace names can choose a primary only among aliases
        // independently confirmed for this live PID; they cannot revive or
        // relabel a reused/unregistered process.
        // The native API accepts bundle identifiers. A code-signing identifier
        // alone is not a bundle ID (for example, /bin/sleep has no Info.plist).
        if aliases.isEmpty, let info = signingInformation(pid),
           let plist = info[kSecCodeInfoPList as String] as? [String:Any],
           let bundle = plist["CFBundleIdentifier"] as? String, !bundle.isEmpty { aliases.insert(bundle) }
        guard let primary = registered.flatMap({ aliases.contains($0) ? $0 : nil })
            ?? workspaceBundle.flatMap({ aliases.contains($0) ? $0 : nil }) ?? aliases.sorted().first else {
            return isAlive(pid) ? .unreadable : .exited
        }
        return .identified(.init(bundle:primary,aliases:aliases))
    }
    static func signingIdentifier(_ pid:pid_t) -> String? {
        signingInformation(pid)?[kSecCodeInfoIdentifier as String] as? String
    }
    private static func signingInformation(_ pid:pid_t) -> [String:Any]? {
        var guest:SecCode?, code:SecStaticCode?, info:CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&guest) == errSecSuccess,
              let guest, SecCodeCopyStaticCode(guest,[],&code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info) == errSecSuccess else { return nil }
        return info as? [String:Any]
    }
}

struct MenuBarResolvedOwners {
    let identities:[pid_t:MenuBarOwnerIdentity]
    let exited:Set<pid_t>
    func removingExited(from snapshot:MenuBarContainerSnapshot) -> MenuBarContainerSnapshot {
        .init(entries:snapshot.entries.filter { !exited.contains($0.pid) },complete:snapshot.complete)
    }
}
