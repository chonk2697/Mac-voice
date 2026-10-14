import Foundation

/// Minimal complex number, enough for polynomial root finding.
struct Complex: Equatable, Sendable {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double) {
        self.re = re
        self.im = im
    }

    static let one = Complex(1, 0)

    var magnitude: Double { hypot(re, im) }
    var phase: Double { atan2(im, re) }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
}

/// Root finding for real-coefficient polynomials.
enum Polynomial {
    /// Roots of the monic polynomial
    /// `z^d + c[0] z^(d-1) + ... + c[d-1]`
    /// using the Durand-Kerner (Weierstrass) simultaneous iteration.
    ///
    /// Degree is small (LPC orders up to about 30), so the O(d^2) per-iteration
    /// cost is negligible. Returns whatever has been reached after `maxIterations`
    /// if the iteration has not converged, which is still useful for formants.
    static func roots(monic c: [Double], maxIterations: Int = 500, tolerance: Double = 1e-12) -> [Complex] {
        let degree = c.count
        guard degree > 0 else { return [] }

        func evaluate(_ z: Complex) -> Complex {
            var result = Complex.one
            for coefficient in c {
                result = result * z + Complex(coefficient, 0)
            }
            return result
        }

        // Initial guesses on a spiral that avoids real-axis symmetry.
        let seed = Complex(0.4, 0.9)
        var z: [Complex] = []
        var power = Complex.one
        for _ in 0..<degree {
            z.append(power)
            power = power * seed
        }

        for _ in 0..<maxIterations {
            var maxStep = 0.0
            for k in 0..<degree {
                var denominator = Complex.one
                for j in 0..<degree where j != k {
                    denominator = denominator * (z[k] - z[j])
                }
                guard denominator.magnitude > 1e-300 else { continue }
                let step = evaluate(z[k]) / denominator
                z[k] = z[k] - step
                maxStep = max(maxStep, step.magnitude)
            }
            if maxStep < tolerance { break }
        }
        return z
    }
}
