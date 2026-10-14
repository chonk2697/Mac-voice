import Foundation

/// Linear predictive coding.
public enum LinearPrediction {
    /// Prediction-error filter `A(z) = 1 + a[1] z^-1 + ... + a[order] z^-order`
    /// fitted with Burg's method (Childers 1978; Press et al. 1992), the method
    /// Praat uses for formant analysis.
    ///
    /// Returns the coefficients `a[0...order]` with `a[0] == 1`, and the final
    /// prediction error power. Returns nil for silent input.
    public static func burg(_ x: [Double], order: Int) -> (coefficients: [Double], error: Double)? {
        let n = x.count
        guard order > 0, n > order else { return nil }

        var forward = x
        var backward = x
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1
        var error = x.reduce(0) { $0 + $1 * $1 } / Double(n)
        guard error > 0 else { return nil }

        for m in 1...order {
            var numerator = 0.0
            var denominator = 0.0
            for i in m..<n {
                numerator += forward[i] * backward[i - 1]
                denominator += forward[i] * forward[i] + backward[i - 1] * backward[i - 1]
            }
            guard denominator > 0 else { break }
            let k = -2 * numerator / denominator

            let previous = a
            for i in 1...m {
                a[i] = previous[i] + k * previous[m - i]
            }

            for i in stride(from: n - 1, through: m, by: -1) {
                let f = forward[i]
                let b = backward[i - 1]
                forward[i] = f + k * b
                backward[i] = b + k * f
            }
            error *= (1 - k * k)
        }
        return (a, error)
    }
}
