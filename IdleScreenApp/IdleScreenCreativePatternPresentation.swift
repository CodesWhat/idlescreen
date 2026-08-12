import IdleScreenCore
import SwiftUI

/// Studio-only presentation metadata for the shared creative pattern contract.
/// Renderer behavior and persistence remain owned by IdleScreenCore/Renderer.
extension IdleScreenCreativePattern {
    var galleryEyebrow: String {
        switch self {
        case .autoCycle: "Rotates every style"
        case .perlin: "Organic noise"
        case .plasma: "Layered waves"
        case .sweep: "Directional motion"
        case .matrixRain: "Falling trails"
        case .rainbowCycle: "Chromatic rhythm"
        case .fireEffect: "Rising heat"
        case .ripple: "Concentric waves"
        case .voronoi: "Living cells"
        case .warp: "Radial speed"
        case .staticNoise: "Signal texture"
        case .pulse: "Breathing light"
        case .dvdBounce: "Classic bounce"
        case .metaballs: "Liquid forms"
        case .starfield: "Deep motion"
        case .spiral: "Galactic swirl"
        case .terrain: "Rolling contours"
        case .rainOnGlass: "Wet refraction"
        case .aurora: "Soft ribbons"
        case .pixelMaterials: "Sand and water worlds"
        }
    }

    var galleryColors: [Color] {
        switch self {
        case .autoCycle: [Color(red: 0.29, green: 0.16, blue: 0.62), Color(red: 0.87, green: 0.28, blue: 0.58)]
        case .perlin: [Color(red: 0.08, green: 0.25, blue: 0.42), Color(red: 0.12, green: 0.63, blue: 0.61)]
        case .plasma: [Color(red: 0.38, green: 0.12, blue: 0.54), Color(red: 0.98, green: 0.35, blue: 0.45)]
        case .sweep: [Color(red: 0.06, green: 0.30, blue: 0.44), Color(red: 0.19, green: 0.73, blue: 0.91)]
        case .matrixRain: [Color(red: 0.02, green: 0.19, blue: 0.10), Color(red: 0.10, green: 0.72, blue: 0.28)]
        case .rainbowCycle: [Color(red: 0.94, green: 0.25, blue: 0.38), Color(red: 0.29, green: 0.44, blue: 0.96)]
        case .fireEffect: [Color(red: 0.38, green: 0.05, blue: 0.02), Color(red: 1.00, green: 0.48, blue: 0.06)]
        case .ripple: [Color(red: 0.03, green: 0.24, blue: 0.49), Color(red: 0.15, green: 0.69, blue: 0.92)]
        case .voronoi: [Color(red: 0.14, green: 0.15, blue: 0.39), Color(red: 0.58, green: 0.44, blue: 0.89)]
        case .warp: [Color(red: 0.05, green: 0.06, blue: 0.19), Color(red: 0.34, green: 0.57, blue: 0.98)]
        case .staticNoise: [Color(red: 0.11, green: 0.12, blue: 0.15), Color(red: 0.57, green: 0.60, blue: 0.66)]
        case .pulse: [Color(red: 0.24, green: 0.06, blue: 0.34), Color(red: 0.85, green: 0.23, blue: 0.71)]
        case .dvdBounce: [Color(red: 0.10, green: 0.18, blue: 0.42), Color(red: 0.58, green: 0.27, blue: 0.93)]
        case .metaballs: [Color(red: 0.04, green: 0.26, blue: 0.29), Color(red: 0.10, green: 0.77, blue: 0.63)]
        case .starfield: [Color(red: 0.02, green: 0.03, blue: 0.12), Color(red: 0.18, green: 0.29, blue: 0.61)]
        case .spiral: [Color(red: 0.14, green: 0.07, blue: 0.34), Color(red: 0.57, green: 0.33, blue: 0.89)]
        case .terrain: [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.53, green: 0.61, blue: 0.25)]
        case .rainOnGlass: [Color(red: 0.05, green: 0.16, blue: 0.32), Color(red: 0.22, green: 0.53, blue: 0.72)]
        case .aurora: [Color(red: 0.04, green: 0.23, blue: 0.26), Color(red: 0.38, green: 0.68, blue: 0.71)]
        case .pixelMaterials: [Color(red: 0.08, green: 0.34, blue: 0.56), Color(red: 0.92, green: 0.56, blue: 0.18)]
        }
    }
}
