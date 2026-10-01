import AppKit
import SwiftUI

/// The sky from spyx's landing page, behind the tour's intro: a clear day,
/// deep blue overhead, with square pixel clouds drifting through — cream on
/// top, grey underneath, where the light does not reach.
///
/// Each layer of cloud is drawn once, a pixel per cloud cell, a little wider
/// than the screen; drifting is that picture sliding along. Nothing is
/// worked out frame by frame, and the motion is smooth rather than a cell at
/// a time.
enum PixelSky {
    struct Layer {
        /// Points per cloud cell.
        let cell: CGFloat
        /// Cells per second.
        let speed: Double
        /// Higher, fewer clouds.
        let threshold: Double
        /// Smaller, bigger clouds.
        let scale: Double
        let seed: UInt32
        /// Sun-lit, body, underside, deep underside — RGBA, 0…255.
        let colors: [(UInt8, UInt8, UInt8, UInt8)]
    }

    static let far = Layer(cell: 9, speed: 0.9, threshold: 0.70, scale: 0.034, seed: 11, colors: [
        (226, 234, 250, 150), (210, 222, 244, 140), (178, 196, 230, 130), (160, 180, 220, 120),
    ])
    static let near = Layer(cell: 12, speed: 1.6, threshold: 0.665, scale: 0.028, seed: 3, colors: [
        (255, 252, 244, 255), (246, 241, 229, 255), (214, 219, 229, 255), (184, 192, 208, 255),
    ])

    /// Top to bottom, as on the page.
    static let gradient = Gradient(stops: [
        .init(color: Color(red: 0x0F / 255, green: 0x2F / 255, blue: 0x86 / 255), location: 0),
        .init(color: Color(red: 0x1B / 255, green: 0x4B / 255, blue: 0xB0 / 255), location: 0.38),
        .init(color: Color(red: 0x3A / 255, green: 0x7F / 255, blue: 0xD6 / 255), location: 0.78),
        .init(color: Color(red: 0x5B / 255, green: 0x9B / 255, blue: 0xE3 / 255), location: 1),
    ])

    /// Cells of slack past the right edge, for the drift to use up: more
    /// than the intro's length at the near layer's speed.
    static let slack = 40

    // MARK: Noise

    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Double {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263 &+ seed &* 2_654_435_761
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h) / Double(UInt32.max)
    }

    static func noise(_ x: Double, _ y: Double, _ seed: UInt32) -> Double {
        let xi = floor(x), yi = floor(y)
        let xf = x - xi, yf = y - yi
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let ix = Int32(xi), iy = Int32(yi)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed)
        let c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    static func fbm(_ x: Double, _ y: Double, _ seed: UInt32) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0
        for octave in 0..<4 {
            sum += amp * noise(x * freq, y * freq, seed &+ UInt32(octave) * 17)
            amp *= 0.5
            freq *= 2.03
        }
        return sum
    }

    // MARK: Drawing

    /// One layer's clouds, a pixel per cell, `columns` wide.
    static func clouds(_ layer: Layer, columns: Int, rows: Int) -> CGImage? {
        guard columns > 0, rows > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        func density(_ x: Int, _ y: Int) -> Double {
            fbm(Double(x) * layer.scale, Double(y) * layer.scale * 1.7, layer.seed)
        }
        let edge = layer.threshold
        for y in 0..<rows {
            for x in 0..<columns {
                guard density(x, y) >= edge else { continue }
                // A lone speck is noise, not a cloud.
                if density(x - 1, y) < edge && density(x + 1, y) < edge { continue }
                // Lit from above: thin above is sun-lit, thin below an underside.
                let above = density(x, y - 2), below = density(x, y + 2)
                let shade = above < edge ? 0 : below < edge ? (below < edge - 0.04 ? 3 : 2) : 1
                let c = layer.colors[shade]
                let i = (y * columns + x) * 4
                // Premultiplied, as the context below expects.
                let a = Double(c.3) / 255
                pixels[i] = UInt8(Double(c.0) * a)
                pixels[i + 1] = UInt8(Double(c.1) * a)
                pixels[i + 2] = UInt8(Double(c.2) * a)
                pixels[i + 3] = c.3
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                      bytesPerRow: columns * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Both layers for a screen of `size`, drawn once and kept.
    @MainActor private static var cache: [String: (far: CGImage?, near: CGImage?)] = [:]

    @MainActor static func layers(for size: CGSize) -> (far: CGImage?, near: CGImage?) {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let hit = cache[key] { return hit }
        func draw(_ layer: Layer) -> CGImage? {
            clouds(layer, columns: Int(ceil(size.width / layer.cell)) + slack, rows: Int(ceil(size.height / layer.cell)) + 1)
        }
        let made = (far: draw(far), near: draw(near))
        cache[key] = made
        return made
    }

    /// Draws the clouds for `size` ahead of time, so the first frame of the
    /// intro does not wait on them.
    @MainActor static func prepare(for size: CGSize) { _ = layers(for: size) }
}

/// The sky, at `t` seconds: the gradient, then the far clouds and the near
/// ones sliding right at their own speeds, thinned in the middle where the
/// intro plays, and softened by `blur`.
struct PixelSkyView: View {
    let t: Double
    let size: CGSize
    var blur: CGFloat = 5

    var body: some View {
        let layers = PixelSky.layers(for: size)
        ZStack(alignment: .topLeading) {
            LinearGradient(gradient: PixelSky.gradient, startPoint: .top, endPoint: .bottom)
            ZStack(alignment: .topLeading) {
                cloud(layers.far, PixelSky.far)
                cloud(layers.near, PixelSky.near)
            }
            .blur(radius: blur, opaque: false)
            // Faint where the pill and the words are, full at the edges.
            .mask(RadialGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                         .init(color: .black.opacity(0.4), location: 0.55),
                                         .init(color: .black, location: 1)],
                                 center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.55))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder private func cloud(_ image: CGImage?, _ layer: PixelSky.Layer) -> some View {
        if let image {
            // Starts with its slack to the left, and slides right into it.
            let slack = CGFloat(PixelSky.slack) * layer.cell
            let drift = CGFloat(t * layer.speed) * layer.cell
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(image.width) * layer.cell, height: CGFloat(image.height) * layer.cell)
                .offset(x: -slack + min(drift, slack))
        }
    }
}
