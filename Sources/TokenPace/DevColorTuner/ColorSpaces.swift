import AppKit

/// Perceptual colour-space maths for the dev colour tuner (#185): sRGB ↔ CIELAB ↔ LCH (D65), and WCAG
/// relative-luminance contrast. Kept as pure functions so the tuner can offer a perceptual lightness
/// (LAB L*), an LCH tone/chroma pair, and live contrast read-outs.
///
/// Ranges: LAB `L` 0–100, `a`/`b` roughly −128…127; LCH `l` 0–100, `c` 0…~132, `h` degrees 0–360.
/// All work on **sRGB** components (0–1); callers resolve appearance-aware colours to sRGB first.
enum ColorSpaces {

    // MARK: sRGB companding

    private static func linearize(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func delinearize(_ v: CGFloat) -> CGFloat {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    private static func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    // MARK: sRGB → XYZ → LAB (D65)

    /// D65 reference white.
    private static let xn: CGFloat = 0.95047, yn: CGFloat = 1.0, zn: CGFloat = 1.08883

    static func labFromSRGB(r: CGFloat, g: CGFloat, b: CGFloat) -> (L: CGFloat, a: CGFloat, b: CGFloat) {
        let rl = linearize(r), gl = linearize(g), bl = linearize(b)
        // Linear sRGB → XYZ (D65).
        let x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
        let y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
        let z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041
        func f(_ t: CGFloat) -> CGFloat {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func srgbFromLAB(L: CGFloat, a: CGFloat, b: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let fy = (L + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        func fInv(_ t: CGFloat) -> CGFloat {
            let t3 = t * t * t
            return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787
        }
        let x = xn * fInv(fx), y = yn * fInv(fy), z = zn * fInv(fz)
        // XYZ → linear sRGB.
        let rl = x * 3.2404542 + y * -1.5371385 + z * -0.4985314
        let gl = x * -0.9692660 + y * 1.8760108 + z * 0.0415560
        let bl = x * 0.0556434 + y * -0.2040259 + z * 1.0572252
        return (clamp01(delinearize(rl)), clamp01(delinearize(gl)), clamp01(delinearize(bl)))
    }

    // MARK: LAB ↔ LCH

    static func lchFromLAB(L: CGFloat, a: CGFloat, b: CGFloat) -> (l: CGFloat, c: CGFloat, h: CGFloat) {
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, c, h)
    }
    static func labFromLCH(l: CGFloat, c: CGFloat, h: CGFloat) -> (L: CGFloat, a: CGFloat, b: CGFloat) {
        let rad = h * .pi / 180
        return (l, c * cos(rad), c * sin(rad))
    }

    // MARK: Convenience on NSColor

    /// LCH of an sRGB-resolved colour.
    static func lch(of color: NSColor) -> (l: CGFloat, c: CGFloat, h: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lab = labFromSRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        return lchFromLAB(L: lab.L, a: lab.a, b: lab.b)
    }
    /// An opaque sRGB colour from LCH (gamut-clamped).
    static func color(l: CGFloat, c: CGFloat, h: CGFloat) -> NSColor {
        let lab = labFromLCH(l: l, c: c, h: h)
        let rgb = srgbFromLAB(L: lab.L, a: lab.a, b: lab.b)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
    /// LAB L* (perceptual lightness, 0–100) of an sRGB-resolved colour.
    static func perceptualLightness(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return labFromSRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent).L
    }
    /// The colour with its LAB L* replaced by `newL`, hue/chroma preserved.
    static func withLightness(_ newL: CGFloat, of color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lab = labFromSRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        let rgb = srgbFromLAB(L: newL, a: lab.a, b: lab.b)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    // MARK: WCAG contrast

    /// WCAG relative luminance of an sRGB-resolved colour.
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = linearize(c.redComponent), g = linearize(c.greenComponent), b = linearize(c.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    /// WCAG contrast ratio between two colours (1…21).
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(of: a), lb = relativeLuminance(of: b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }
}
