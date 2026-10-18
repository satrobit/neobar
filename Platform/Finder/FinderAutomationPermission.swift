import Carbon
import Foundation

enum FinderAutomationPermission {
    static func status(askUserIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let result = bundleID.withCString {
            AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &target)
        }
        guard result == noErr else { return OSStatus(result) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard,
                                                    askUserIfNeeded)
    }
}
