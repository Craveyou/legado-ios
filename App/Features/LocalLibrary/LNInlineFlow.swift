import Foundation

/// [图NN] 定位标记 → 图片内嵌的渲染流。
/// 照搬 LocalNovel ReaderView.swift 的 inlineImageFlow（约 80 行纯逻辑，iOS 15 全兼容）。
/// 规则：
/// · [图3] / [图03] / 【图3】 的 NN 是图片序号，对应按文件名数字命名的图片；
/// · 命中未被占用的图片 → 嵌到标记位置；无对应图片 → 标记原样留成文字；
/// · 全章无标记 → 返回空数组，走「正文 → 插图」原排布；
/// · 未被任何标记引用的图片 → 由阅读页放章末插图区兜底。
enum LNInlineFlow {

    /// 渲染流里的一块
    enum Block: Sendable {
        case paragraph(String, paragraphIndex: Int, segmentIndex: Int)
        case inlineImage(index: Int)
    }

    /// [图3] / [图03] / 【图3】
    private static let markerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\[[ \\t]*图[ \\t]*(\\d{1,3})[ \\t]*\\]|【[ \\t]*图[ \\t]*(\\d{1,3})[ \\t]*】"
    )

    /// 只作用于「整理」分区
    static func blocks(paragraphs: [String], images: [LNMediaItem],
                       category: LNCategory) -> [Block] {
        guard category == .organized, !images.isEmpty, !paragraphs.isEmpty,
              let regex = markerRegex else { return [] }

        var queueBySequence: [Int: [Int]] = [:]
        for (index, item) in images.enumerated() {
            if let seq = item.sequence {
                queueBySequence[seq, default: []].append(index)
            }
        }
        var used = Set<Int>()
        var blocks: [Block] = []

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let ns = paragraph as NSString
            let matches = regex.matches(in: paragraph,
                                        range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else {
                blocks.append(.paragraph(paragraph, paragraphIndex: paragraphIndex,
                                         segmentIndex: 0))
                continue
            }
            var segment = 0
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    let head = ns.substring(with: NSRange(location: cursor,
                                                          length: match.range.location - cursor))
                    if !head.isEmpty {
                        blocks.append(.paragraph(head, paragraphIndex: paragraphIndex,
                                                 segmentIndex: segment))
                        segment += 1
                    }
                }
                // 两个捕获组二选一
                let group = match.range(at: 1).location != NSNotFound ? 1 : 2
                let seq = Int(ns.substring(with: match.range(at: group))) ?? -1
                if let index = (queueBySequence[seq] ?? []).first(where: { !used.contains($0) }) {
                    used.insert(index)
                    blocks.append(.inlineImage(index: index))
                } else {
                    // 没有可用图片：标记原样留着
                    let marker = ns.substring(with: match.range)
                    blocks.append(.paragraph(marker, paragraphIndex: paragraphIndex,
                                             segmentIndex: segment))
                    segment += 1
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                let tail = ns.substring(with: NSRange(location: cursor,
                                                      length: ns.length - cursor))
                if !tail.isEmpty {
                    blocks.append(.paragraph(tail, paragraphIndex: paragraphIndex,
                                             segmentIndex: segment))
                }
            }
        }
        return blocks
    }

    /// 被标记引用的图片下标集合（其余走章末兜底）
    static func matchedIndexes(_ blocks: [Block]) -> Set<Int> {
        var result = Set<Int>()
        for block in blocks {
            if case .inlineImage(let index) = block { result.insert(index) }
        }
        return result
    }
}
