import Foundation

/// 一章解析后的内容
struct LNChapterContent {
    let chapter: LNChapter
    let paragraphs: [String]
    let textPath: String?
    let images: [LNMediaItem]
    let avMedia: [LNMediaItem]
    let pdfPath: String?
    let ignoredCount: Int

    var isEmpty: Bool {
        paragraphs.isEmpty && images.isEmpty && avMedia.isEmpty && pdfPath == nil
    }
}

/// 把一章里的节点装配成正文 → 图片 → 章末音视频。
/// 参照 LocalNovel MediaResolver.resolveChapter，改为基于 source + path（本地/NAS 通用）。
enum LNContentLoader {

    static func load(_ chapter: LNChapter, source: any LNLibrarySource) async throws -> LNChapterContent {
        let path = chapter.path

        // 单文件章节
        if chapter.kind == .pdf {
            return LNChapterContent(chapter: chapter, paragraphs: [], textPath: nil,
                                    images: [], avMedia: [], pdfPath: path, ignoredCount: 0)
        }
        if chapter.kind == .video {
            let item = LNMediaItem(path: path, fileName: (path as NSString).lastPathComponent,
                                   kind: .video)
            return LNChapterContent(chapter: chapter, paragraphs: [], textPath: nil,
                                    images: [], avMedia: [item], pdfPath: nil, ignoredCount: 0)
        }
        if chapter.kind == .audio {
            let item = LNMediaItem(path: path, fileName: (path as NSString).lastPathComponent,
                                   kind: .audio)
            return LNChapterContent(chapter: chapter, paragraphs: [], textPath: nil,
                                    images: [], avMedia: [item], pdfPath: nil, ignoredCount: 0)
        }
        if chapter.kind == .text {
            return try await textChapter(chapter, textPath: path, source: source)
        }

        // 目录章 / 图片话：列目录
        let nodes = try await source.list(at: path)
        if chapter.kind == .images {
            var images: [LNMediaItem] = []
            for node in nodes.filter({ LNScanner.isImage($0) }) {
                images.append(mediaItem(node))
            }
            images = LNNaturalSort.sorted(images) { $0.fileName }
            return LNChapterContent(chapter: chapter, paragraphs: [], textPath: nil,
                                    images: images, avMedia: [], pdfPath: nil, ignoredCount: 0)
        }

        var texts: [LNNode] = []
        var images: [LNMediaItem] = []
        var av: [LNMediaItem] = []
        var pdfPath: String?
        var ignored = 0
        for node in nodes {
            if LNScanner.isText(node) { texts.append(node) }
            else if LNScanner.isImage(node) { images.append(mediaItem(node)) }
            else if LNScanner.isVideo(node) {
                av.append(LNMediaItem(path: node.path, fileName: node.name, kind: .video))
            } else if LNScanner.isAudio(node) {
                av.append(LNMediaItem(path: node.path, fileName: node.name, kind: .audio))
            } else if LNScanner.isPDF(node) {
                if pdfPath == nil { pdfPath = node.path } else { ignored += 1 }
            }
        }

        let sortedTexts = LNNaturalSort.sorted(texts) { $0.name }
        let textPath = sortedTexts.first?.path
        if sortedTexts.count > 1 { ignored += sortedTexts.count - 1 }

        // 图片：有序号按数值升序，无序号排在后面
        let withSeq = images.filter { $0.sequence != nil }
            .sorted {
                if $0.sequence! != $1.sequence! { return $0.sequence! < $1.sequence! }
                return LNNaturalSort.less($0.fileName, $1.fileName)
            }
        let withoutSeq = images.filter { $0.sequence == nil }
            .sorted { LNNaturalSort.less($0.fileName, $1.fileName) }

        var paragraphs: [String] = []
        if let textPath {
            paragraphs = try await loadParagraphs(textPath, source: source)
        }
        return LNChapterContent(chapter: chapter, paragraphs: paragraphs,
                                textPath: textPath, images: withSeq + withoutSeq,
                                avMedia: LNNaturalSort.sorted(av) { $0.fileName },
                                pdfPath: pdfPath, ignoredCount: ignored)
    }

    private static func textChapter(_ chapter: LNChapter, textPath: String,
                                    source: any LNLibrarySource) async throws -> LNChapterContent {
        let paragraphs = try await loadParagraphs(textPath, source: source)
        return LNChapterContent(chapter: chapter, paragraphs: paragraphs,
                                textPath: textPath, images: [], avMedia: [],
                                pdfPath: nil, ignoredCount: 0)
    }

    private static func loadParagraphs(_ path: String,
                                       source: any LNLibrarySource) async throws -> [String] {
        let url = try await source.localURL(for: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = LNTextDecoder.decode(data) else {
            return []
        }
        return LNTextDecoder.paragraphs(text)
    }

    private static func mediaItem(_ node: LNNode) -> LNMediaItem {
        let animated = LNScanner.animatedExts.contains(LNScanner.ext(node.name))
        return LNMediaItem(path: node.path, fileName: node.name,
                           kind: animated ? .animatedImage : .image,
                           sequence: LNScanner.sequence(node.name),
                           isAnimated: animated)
    }
}
