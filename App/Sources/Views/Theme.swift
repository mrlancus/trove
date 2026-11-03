import SwiftUI

/// Trove's design tokens (docs/DEVELOP_PLAN.md decision 16: direction A Glass, glass on floating
/// controls only). Colours, corner radii and spacing live here, so switching to direction B
/// (Editorial) or C (Midnight) from the mockups is a change in this one file. Views move onto these as
/// they're touched; `card`, `glass` and Develop use them already.
enum Theme {
    /// The direction in use.
    static let direction = Direction.glass
    enum Direction { case glass, editorial, midnight }

    /// Trove's orange (from the icon): primary actions, Ask, Develop.
    static var accent: Color {
        switch direction {
        case .glass: Brand.orange
        case .editorial: Color(red: 0.75, green: 0.27, blue: 0.16)
        case .midnight: Brand.amber
        }
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// The widest a reading column gets (line length stays readable on a 13-inch iPad or a big window).
    static let readingWidth: CGFloat = 760
}
