import CoreGraphics

/// Spacing tokens. `s4` (16pt) is the one gutter from the screen edge.
public enum Space {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32
    /// Minimum hit target in both directions.
    public static let tap: CGFloat = 44
}

/// Corner radii, concentric with the device corner.
public enum Radius {
    /// 40pt artwork in track rows.
    public static let coverSmall: CGFloat = 6
    /// 56–96pt playlist artwork.
    public static let cover: CGFloat = 12
    /// Inset-grouped list sections.
    public static let row: CGFloat = 18
    /// Sync cards and panels inset 16pt from the screen edge.
    public static let card: CGFloat = 26
}

public enum Opacity {
    /// Rows for tracks not available on the other side.
    public static let missing: Double = 0.55
    public static let disabled: Double = 0.4
}
