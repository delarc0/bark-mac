import AppKit

// The notch of a built-in display, measured from public APIs. Nil whenever no
// notched screen is active: a docked-clamshell Mac drops its built-in display
// out of NSScreen.screens entirely, external displays have no notch, and Macs
// without a notch never report one.
struct NotchGeometry {
    /// The notched screen (global, bottom-left origin coordinates).
    let screen: NSScreen
    /// Menu-bar height at the notch = the cutout's height.
    let height: CGFloat
    /// The cutout's width: total minus the usable menu-bar area on each side.
    let width: CGFloat

    /// Geometry for the screen the pointer is on, if that screen is notched.
    /// The pointer's screen is where the user is typing, so it's the only place
    /// an island would make sense.
    static func forPointerScreen() -> NotchGeometry? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else {
            return nil
        }
        return NotchGeometry(screen: screen)
    }

    init?(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return nil }  // no notch on this screen

        // On a notched Mac the two auxiliary areas are the menu-bar strips left
        // and right of the camera housing; the gap between them is the notch.
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0
        let notchW = screen.frame.width - leftW - rightW

        // Refuse implausible geometry rather than draw a black slab across the
        // menu bar: every shipping notch is roughly 150-220pt wide under a
        // 30-40pt inset, and the pill is always a correct fallback.
        guard (100...400).contains(notchW), (24...60).contains(top) else { return nil }

        self.screen = screen
        self.height = top
        self.width = notchW
    }
}
