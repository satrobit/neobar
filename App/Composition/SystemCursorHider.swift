import CoreGraphics
import Foundation

/// A single process-wide hide, owned by the unit currently drawing the replacement cursor.
/// A late hover-exit from another screen must not reveal the arrow underneath that glyph.
///
/// WindowServer ignores `CGDisplayHideCursor` from a process that is not frontmost — it still
/// returns `.success` — unless the connection carries `SetsCursorInBackground`. This app is
/// never frontmost, so without the property the arrow stays on top of the glyph. When the
/// property cannot be set the hide reports failure and the caller shows no glyph at all.
@MainActor
final class SystemCursorHider {
    static let shared = SystemCursorHider()
    private var owner: String?
    var isHidden: Bool { owner != nil }
    private let hideCursor: () -> CGError
    private let showCursor: () -> CGError

    nonisolated private static let allowsBackgroundCursorControl: Bool = {
        typealias MainConnectionIDFn = @convention(c) () -> Int32
        typealias SetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let cidSymbol = dlsym(handle, "SLSMainConnectionID"),
              let setSymbol = dlsym(handle, "SLSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(cidSymbol, to: MainConnectionIDFn.self)()
        let set = unsafeBitCast(setSymbol, to: SetConnectionPropertyFn.self)
        return set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    init(hideCursor: @escaping () -> CGError = {
             guard SystemCursorHider.allowsBackgroundCursorControl else { return .failure }
             return CGDisplayHideCursor(CGMainDisplayID())
         },
         showCursor: @escaping () -> CGError = { CGDisplayShowCursor(CGMainDisplayID()) }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    @discardableResult
    func hide(owner: String) -> Bool {
        if !isHidden, hideCursor() != .success { return false }
        self.owner = owner
        return true
    }

    func show(owner: String) {
        guard self.owner == owner else { return }
        show()
    }

    /// Unconditional release is reserved for application termination.
    func show() {
        guard isHidden else { return }
        guard showCursor() == .success else { return }
        owner = nil
    }
}
