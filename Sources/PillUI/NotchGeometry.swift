import AppKit

/// A display's physical notch, in global (bottom-left origin) screen coordinates.
///
/// Nothing is drawable *inside* this rect — it is a cutout, not pixels. It
/// matters because it tells us where the black begins: a shape drawn flush
/// against the screen's top edge, centred on the notch and wider than it, reads
/// as the notch itself growing.
public struct NotchInfo: Equatable {
    public let rect: CGRect
    /// The screen the notch belongs to.
    public let screenFrame: CGRect

    public var width: CGFloat { rect.width }
    public var height: CGFloat { rect.height }
    public var centerX: CGFloat { rect.midX }
}

public enum NotchGeometry {
    /// The notch on `screen`, or nil for displays without one (every external
    /// monitor, and pre-2021 built-in displays).
    ///
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the menu-bar strips
    /// either side of the cutout; the gap between them is the notch, and
    /// `safeAreaInsets.top` is how far down it hangs.
    public static func notch(on screen: NSScreen) -> NotchInfo? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }

        let rect = CGRect(
            x: left.maxX,
            y: screen.frame.maxY - inset,
            width: right.minX - left.maxX,
            height: inset
        )
        // Sanity: a real notch is ~180 pt wide. Anything tiny is a layout quirk.
        guard rect.width > 60 else { return nil }
        return NotchInfo(rect: rect, screenFrame: screen.frame)
    }

    /// The notch on the screen under the pointer, if that screen has one. The
    /// pill belongs where the user is working, so a pointer on an external
    /// display means no notch and the floating pill takes over.
    public static func notchUnderPointer() -> NotchInfo? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen.flatMap(notch(on:))
    }
}
