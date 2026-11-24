import SwiftUI
import UIKit
import PDFKit

/// PDF 单话按页渲染。参照 LocalNovel PdfChapterView（PDFKit，iOS 15 兼容）。
/// 大文件不一次性转图：每页可见时才异步渲染，离屏由 SwiftUI 释放。
final class LNPDFRenderer: @unchecked Sendable {
    static let shared = LNPDFRenderer()

    private let queue = DispatchQueue(label: "ln.pdf.render", qos: .userInitiated)
    private let lock = NSLock()
    private var documents: [String: PDFDocument] = [:]

    func pageCount(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return documentLocked(url)?.pageCount ?? 0
    }

    func image(url: URL, page: Int, maxPixel: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            queue.async {
                self.lock.lock()
                let doc = self.documentLocked(url)
                self.lock.unlock()
                guard let doc, let pageRef = doc.page(at: page) else {
                    continuation.resume(returning: nil)
                    return
                }
                let box = pageRef.bounds(for: .mediaBox)
                guard box.width > 1, box.height > 1 else {
                    continuation.resume(returning: nil)
                    return
                }
                let width = max(600, maxPixel)
                let height = width * box.height / box.width
                let image = pageRef.thumbnail(of: CGSize(width: width, height: height),
                                              for: .mediaBox)
                continuation.resume(returning: image)
            }
        }
    }

    private func documentLocked(_ url: URL) -> PDFDocument? {
        if let cached = documents[url.path] { return cached }
        guard let doc = PDFDocument(url: url) else { return nil }
        if documents.count > 3 { documents.removeAll() }
        documents[url.path] = doc
        return doc
    }
}

struct LNPDFView: View {
    let path: String
    let source: any LNLibrarySource

    @State private var url: URL?
    @State private var pageCount = 0
    @State private var didFail = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if didFail {
                    ReadingUnavailableView("无法打开这个 PDF", systemImage: "doc.questionmark",
                                           description: Text((path as NSString).lastPathComponent))
                        .padding(.top, 40)
                } else if pageCount == 0 {
                    ProgressView("正在读取 PDF…")
                        .padding(.top, 60)
                } else if let url {
                    ForEach(0..<pageCount, id: \.self) { index in
                        LNPDFPageView(url: url, index: index)
                    }
                    Text("\(pageCount) 页 · 完")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }
        }
        .task(id: path) {
            guard let resolved = try? await source.localURL(for: path) else {
                didFail = true
                return
            }
            url = resolved
            let count = await Task.detached(priority: .userInitiated) {
                LNPDFRenderer.shared.pageCount(resolved)
            }.value
            pageCount = count
            didFail = count == 0
        }
    }
}

private struct LNPDFPageView: View {
    let url: URL
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 320)
                    .overlay(ProgressView())
            }
        }
        .task {
            guard image == nil else { return }
            image = await LNPDFRenderer.shared.image(url: url, page: index, maxPixel: 1200)
        }
    }
}
