import Foundation

public struct IdleScreenAnimationFrame: Equatable, Sendable {
    public static let loopDuration: TimeInterval = 12
    private static let glyphs = ["·", ":", "+", "*", "#", "%", "@", "%", "#", "*", "+", ":"]

    public var progress: Double
    public var backgroundHue: Double
    public var accentHue: Double
    public var glyph: String

    public init(
        progress: Double,
        backgroundHue: Double,
        accentHue: Double,
        glyph: String
    ) {
        self.progress = progress
        self.backgroundHue = backgroundHue
        self.accentHue = accentHue
        self.glyph = glyph
    }

    public static func sample(at elapsedTime: TimeInterval) -> IdleScreenAnimationFrame {
        let elapsedTime = max(0, elapsedTime)
        let loopTime = elapsedTime.truncatingRemainder(dividingBy: loopDuration)
        let progress = loopTime / loopDuration
        let glyphIndex = Int(floor(progress * Double(glyphs.count))) % glyphs.count

        return IdleScreenAnimationFrame(
            progress: progress,
            backgroundHue: (0.04 + progress * 0.14).truncatingRemainder(dividingBy: 1),
            accentHue: (0.08 + progress * 0.22).truncatingRemainder(dividingBy: 1),
            glyph: glyphs[glyphIndex]
        )
    }
}
