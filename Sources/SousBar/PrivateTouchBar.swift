import AppKit
import ObjectiveC

/// Private API that lets a background app put an item in the Control Strip and
/// show a full-width Touch Bar on top of whatever app is in front.
/// MTMR and Pock rely on the same calls. They can change in a macOS update.
enum PrivateTouchBar {
    private typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void
    private typealias CloseBoxFn = @convention(c) (Bool) -> Void
    private typealias OneArgFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias TwoArgFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
    private typealias PlacementFn = @convention(c) (AnyObject, Selector, AnyObject, Int64, AnyObject) -> Void

    private static let dfr: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static func dfrSymbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle = dfr, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static func classMethod(_ cls: AnyClass, _ name: String) -> (IMP, Selector)? {
        let sel = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        return (method_getImplementation(method), sel)
    }

    static var isAvailable: Bool {
        classMethod(NSTouchBarItem.self, "addSystemTrayItem:") != nil
    }

    static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ present: Bool) {
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", SetPresenceFn.self)?(id.rawValue as NSString, present)
    }

    static func setCloseBoxShown(_ shown: Bool) {
        dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", CloseBoxFn.self)?(shown)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        guard let m = classMethod(NSTouchBarItem.self, "addSystemTrayItem:") else { return }
        unsafeBitCast(m.0, to: OneArgFn.self)(NSTouchBarItem.self as AnyObject, m.1, item)
    }

    /// Shows `bar` full width over the current app's Touch Bar.
    static func present(_ bar: NSTouchBar, trayId: NSTouchBarItem.Identifier) {
        let cls: AnyClass = NSTouchBar.self
        let target = NSTouchBar.self as AnyObject
        let ident = trayId.rawValue as NSString
        for name in ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"] {
            if let m = classMethod(cls, name) {
                unsafeBitCast(m.0, to: PlacementFn.self)(target, m.1, bar, 1, ident)
                return
            }
        }
        for name in ["presentSystemModalTouchBar:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:systemTrayItemIdentifier:"] {
            if let m = classMethod(cls, name) {
                unsafeBitCast(m.0, to: TwoArgFn.self)(target, m.1, bar, ident)
                return
            }
        }
    }

    /// Hands the Touch Bar back to the front app; our pill stays in the Control Strip.
    static func minimize(_ bar: NSTouchBar) {
        let target = NSTouchBar.self as AnyObject
        for name in ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:",
                     "dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
            if let m = classMethod(NSTouchBar.self, name) {
                unsafeBitCast(m.0, to: OneArgFn.self)(target, m.1, bar)
                return
            }
        }
    }
}
