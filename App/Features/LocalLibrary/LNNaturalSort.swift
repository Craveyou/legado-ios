import Foundation

/// 自然排序：1 < 2 < 10，中文按拼音不依赖 locale 的 compare 兜底。
/// 参照 LocalNovel NaturalSort，纯逻辑照搬。
enum LNNaturalSort {
    static func less(_ a: String, _ b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let an = a as NSString, bn = b as NSString
        var i = 0, j = 0
        while i < an.length && j < bn.length {
            let ca = an.character(at: i)
            let cb = bn.character(at: j)
            if isDigit(ca) && isDigit(cb) {
                var na = 0, nb = 0
                while i < an.length && isDigit(an.character(at: i)) {
                    na = na &* 10 + Int(an.character(at: i) - 48)
                    i += 1
                }
                while j < bn.length && isDigit(bn.character(at: j)) {
                    nb = nb &* 10 + Int(bn.character(at: j) - 48)
                    j += 1
                }
                if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
                continue
            }
            if ca != cb {
                return a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
                    ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }
        if i >= an.length && j >= bn.length { return .orderedSame }
        return i >= an.length ? .orderedAscending : .orderedDescending
    }

    static func sorted<S: Sequence>(_ seq: S, _ key: (S.Element) -> String) -> [S.Element] {
        seq.sorted { less(key($0), key($1)) }
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
}
