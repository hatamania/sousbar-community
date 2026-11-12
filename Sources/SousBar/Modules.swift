import AppKit

/// An app on the launcher layer, next to Claude: feeds, a clock, a build status…
///
/// Tapping the pill opens the launcher (one button per module). Tapping a module's button gives
/// it the bar: a back button (to the launcher), then `barViews()`, then the hide button.
///
/// To add one: write a class that conforms, and add an instance to `TouchBarController.modules`
/// (in `AppDelegate`). Approvals from Claude always take over the bar, whatever is open.
protocol BarModule: AnyObject {
    /// Stable id, e.g. "feeds". Used in `sousbar://open/<id>`.
    var id: String { get }
    /// Launcher button label.
    var title: String { get }
    var icon: Icon { get }
    /// Launcher button color, e.g. to flag unread items. nil = neutral gray.
    var tint: NSColor? { get }
    /// What the bar shows while this module is open, left to right. The back and hide buttons are
    /// added for you. Put a stretchy view (a text field or `TouchBarController.spacer()`) before
    /// buttons that should sit at the right edge. Views are rebuilt each time, so don't cache them.
    func barViews() -> [NSView]
    /// Set by the bar. Declare it `weak var host: BarHost?`.
    var host: BarHost? { get set }
}

/// What a module can ask of the bar.
protocol BarHost: AnyObject {
    /// Content or tint changed: redraw if the module (or the launcher) is showing.
    func moduleDidChange(_ module: BarModule)
    /// Something new arrived: show the module on the Touch Bar for a few seconds, if the bar
    /// isn't busy. It closes by itself unless you touch it.
    func moduleWantsAttention(_ module: BarModule)
}
