import Foundation

/// A color in CIELAB, with the D65 reference white of sRGB.
public struct LabColor: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From 8-bit sRGB (IEC 61966-2-1): linearize, convert to CIE XYZ, then to CIELAB relative
    /// to D65, the white point sRGB itself is defined with, so no chromatic adaptation is
    /// involved.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
}

/// Colour distances between two CIELAB colors.
///
/// The parity thresholds (specification section 15.7) are stated as "ΔE 2" without naming a
/// formula. The gate uses CIEDE2000, the CIE's current recommendation (CIE 142-2001, in the
/// formulation of Sharma, Wu and Dalal, 2005) and the formula under which one unit is close to
/// one just-noticeable difference across the gamut, which is what a threshold of 2 means.
/// CIE76, the plain Euclidean distance in CIELAB, is reported next to it for reference; it
/// overstates differences between saturated colors and understates some between dark neutrals.
public enum ColorDifference {
    /// CIE76: Euclidean distance in CIELAB.
    public static func cie76(_ first: LabColor, _ second: LabColor) -> Double {
        let dl = first.l - second.l, da = first.a - second.a, db = first.b - second.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// CIEDE2000 with the parametric factors kL = kC = kH = 1.
    public static func ciede2000(_ first: LabColor, _ second: LabColor) -> Double {
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        let pow25to7 = 6_103_515_625.0

        let c1 = (first.a * first.a + first.b * first.b).squareRoot()
        let c2 = (second.a * second.a + second.b * second.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow25to7)).squareRoot())
        let a1 = (1 + g) * first.a
        let a2 = (1 + g) * second.a
        let c1Prime = (a1 * a1 + first.b * first.b).squareRoot()
        let c2Prime = (a2 * a2 + second.b * second.b).squareRoot()

        func hue(_ b: Double, _ a: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let angle = degrees(atan2(b, a))
            return angle >= 0 ? angle : angle + 360
        }
        let h1 = hue(first.b, a1)
        let h2 = hue(second.b, a2)

        let deltaL = second.l - first.l
        let deltaC = c2Prime - c1Prime
        var deltaHue = 0.0
        if c1Prime * c2Prime != 0 {
            deltaHue = h2 - h1
            if deltaHue > 180 { deltaHue -= 360 } else if deltaHue < -180 { deltaHue += 360 }
        }
        let deltaH = 2 * (c1Prime * c2Prime).squareRoot() * sin(radians(deltaHue / 2))

        let lBar = (first.l + second.l) / 2
        let cBarPrime = (c1Prime + c2Prime) / 2
        var hBar = h1 + h2
        if c1Prime * c2Prime != 0 {
            if abs(h1 - h2) <= 180 {
                hBar = (h1 + h2) / 2
            } else if h1 + h2 < 360 {
                hBar = (h1 + h2 + 360) / 2
            } else {
                hBar = (h1 + h2 - 360) / 2
            }
        }
        let t = 1 - 0.17 * cos(radians(hBar - 30)) + 0.24 * cos(radians(2 * hBar))
            + 0.32 * cos(radians(3 * hBar + 6)) - 0.20 * cos(radians(4 * hBar - 63))
        let deltaTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cBarPrime7 = pow(cBarPrime, 7)
        let rC = 2 * (cBarPrime7 / (cBarPrime7 + pow25to7)).squareRoot()
        let lTerm = (lBar - 50) * (lBar - 50)
        let sL = 1 + 0.015 * lTerm / (20 + lTerm).squareRoot()
        let sC = 1 + 0.045 * cBarPrime
        let sH = 1 + 0.015 * cBarPrime * t
        let rT = -sin(radians(2 * deltaTheta)) * rC

        let l = deltaL / sL, c = deltaC / sC, h = deltaH / sH
        return max(0, l * l + c * c + h * h + rT * c * h).squareRoot()
    }
}
