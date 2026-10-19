import Foundation

/// Line-based 3-way merge (diff3). Returns nil when both sides changed the same region differently;
/// callers then keep "ours" and store "theirs" as a conflict copy, so nothing is lost.
public enum TextMerge {
    public static func merge(base: String, ours: String, theirs: String) -> String? {
        if ours == theirs || theirs == base { return ours }
        if ours == base { return theirs }
        let b = lines(base), o = lines(ours), t = lines(theirs)
        let mo = matches(b, o), mt = matches(b, t)

        var out: [Substring] = []
        var i = 0, j = 0, k = 0
        while true {
            if j < b.count, mo[j] == i, mt[j] == k {
                out.append(b[j])
                i += 1; j += 1; k += 1
                continue
            }
            // Next base line both sides still share, or the ends of all three.
            var j2 = j
            while j2 < b.count, mo[j2] == nil || mt[j2] == nil { j2 += 1 }
            let i2 = j2 < b.count ? mo[j2]! : o.count
            let k2 = j2 < b.count ? mt[j2]! : t.count
            let oc = o[i..<i2], bc = b[j..<j2], tc = t[k..<k2]
            if oc.elementsEqual(bc) { out.append(contentsOf: tc) }
            else if tc.elementsEqual(bc) || oc.elementsEqual(tc) { out.append(contentsOf: oc) }
            else { return nil }
            i = i2; j = j2; k = k2
            if j >= b.count, i >= o.count, k >= t.count { break }
        }
        return out.joined(separator: "\n")
    }

    static func lines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }

    /// For each line of `a`, the index of the matching line in `b` along a longest common
    /// subsequence (Myers O(ND)), or nil.
    static func matches(_ a: [Substring], _ b: [Substring]) -> [Int?] {
        let n = a.count, m = b.count
        var result = [Int?](repeating: nil, count: n)
        if n == 0 || m == 0 { return result }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        outer: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { break outer }
            }
        }
        // Walk the trace backwards collecting the diagonal (matching) moves.
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = d == 0 ? 0 : vd[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1; y -= 1
                result[x] = y
            }
            if d == 0 { break }
            x = prevX; y = prevY
        }
        return result
    }
}
