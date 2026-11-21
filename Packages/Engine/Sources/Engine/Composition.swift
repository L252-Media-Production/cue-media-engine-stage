import CoreGraphics
import Foundation

/// What a layer shows.
public enum LayerContent {
    /// Frames from a source: a looping file, an NDI input or an SDI input.
    case video(FrameSource)
    /// A transparent text layer (slides, lower thirds, messages).
    case text(TextLayer)
    /// The animated test pattern (master composition only).
    case pattern
}

/// One layer of a composition. Layers are drawn bottom to top.
public final class CompositionLayer {
    public var name: String
    public var content: LayerContent
    /// Where the layer sits inside its composition (pixels); nil fills the composition.
    public var rect: ScreenRegion?
    public var opacity: Float
    public var fit: LayerFit
    public var isVisible: Bool

    public init(name: String, content: LayerContent, rect: ScreenRegion? = nil,
                opacity: Float = 1, fit: LayerFit = .stretch, isVisible: Bool = true) {
        self.name = name
        self.content = content
        self.rect = rect
        self.opacity = opacity
        self.fit = fit
        self.isVisible = isVisible
    }
}

/// One screen: its place on the canvas, its own layers, and whether the master shows through.
public final class ScreenComposition {
    public var name: String
    public var region: ScreenRegion
    public var showMaster: Bool
    /// Bottom to top.
    public var layers: [CompositionLayer]

    public init(name: String, region: ScreenRegion, showMaster: Bool = true, layers: [CompositionLayer] = []) {
        self.name = name
        self.region = region
        self.showMaster = showMaster
        self.layers = layers
    }
}
