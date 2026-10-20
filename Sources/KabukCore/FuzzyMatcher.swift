import Foundation

/// Subsequence matching for the command palette. Consecutive letters and word starts score higher.
public enum FuzzyMatcher {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let c = Array(candidate.lowercased())
        var qi = 0
        var score = 0
        var previousMatch = -2
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if ci == previousMatch + 1 { score += 4 }
            if ci == 0 || " -_/.".contains(c[ci - 1]) { score += 6 }
            previousMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - c.count / 10
    }
}
