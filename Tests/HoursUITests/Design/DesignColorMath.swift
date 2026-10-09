import Foundation

/// Reference colour maths for the token tests: WCAG 2.x contrast, CIELAB (D65),
/// CIEDE2000, and Machado et al. (2009) full-severity CVD simulation in linear sRGB.
enum ColorMath {
    typealias RGB = (r: Double, g: Double, b: Double)
    typealias Lab = (l: Double, a: Double, b: Double)

    static func rgb(_ h: UInt32) -> RGB {
        (Double((h >> 16) & 0xFF) / 255, Double((h >> 8) & 0xFF) / 255, Double(h & 0xFF) / 255)
    }

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double {
        let x = min(max(c, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// WCAG relative luminance.
    static func luminance(_ h: UInt32) -> Double {
        let c = rgb(h)
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio, 1…21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    enum CVD: String, CaseIterable { case deuteranopia, protanopia, tritanopia }

    static func matrix(_ cvd: CVD) -> [[Double]] {
        switch cvd {
        case .deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        case .protanopia:   [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .tritanopia:   [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
        }
    }

    static func simulate(_ h: UInt32, _ cvd: CVD?) -> RGB {
        let c = rgb(h)
        guard let cvd else { return c }
        let l = [linear(c.r), linear(c.g), linear(c.b)]
        let o = matrix(cvd).map { $0[0] * l[0] + $0[1] * l[1] + $0[2] * l[2] }
        return (gamma(o[0]), gamma(o[1]), gamma(o[2]))
    }

    static func lab(_ c: RGB) -> Lab {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// ΔE between two hexes as seen with `cvd` (nil = normal vision).
    static func deltaE(_ a: UInt32, _ b: UInt32, _ cvd: CVD? = nil) -> Double {
        ciede2000(lab(simulate(a, cvd)), lab(simulate(b, cvd)))
    }

    /// CIEDE2000 (Sharma, Wu & Dalal 2005), kL = kC = kH = 1.
    static func ciede2000(_ p: Lab, _ q: Lab) -> Double {
        let rad = Double.pi / 180
        let c1 = hypot(p.a, p.b), c2 = hypot(q.a, q.b), cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let c1p = hypot(a1, p.b), c2p = hypot(a2, q.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dL = q.l - p.l, dC = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(c1p * c2p) * sin(dh / 2 * rad)
        let lBar = (p.l + q.l) / 2, cBarP = (c1p + c2p) / 2
        var hBar = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) > 180 { hBar = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2 } else { hBar = (h1 + h2) / 2 }
        }
        let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad)
            + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rC = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
        let sL = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sC = 1 + 0.045 * cBarP, sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * rad) * rC
        return sqrt(pow(dL / sL, 2) + pow(dC / sC, 2) + pow(dH / sH, 2) + rT * (dC / sC) * (dH / sH))
    }
}
