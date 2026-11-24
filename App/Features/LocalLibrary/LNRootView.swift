import SwiftUI

/// 本地 tab 的根视图：漫画 / 整理 / 短剧三个入口。
/// NAS tab 的 CategoryView 复用同一个组件，只换 source。
struct LNCategoryView: View {
    let source: any LNLibrarySource
    let title: String
    let subtitle: String
    /// NAS 首屏不预统计（三类各一次远端探测会拖慢进入），进入分类时再加载
    var showsCounts: Bool = true
    /// 页面底部附加内容（NAS 用来放「浏览全部文件」入口）
    var extraContent: AnyView? = nil

    @State private var counts: [LNCategory: Int] = [:]
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReadingPageHeader(title: title, subtitle: subtitle) {
                    // 与 NAS tab 头部保持一致（NAS 用 + 添加连接）；
                    // 本地书库通过「文件」App 放书，这里用空操作占位保持视觉对称。
                    EmptyView()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(LNCategory.allCases) { cat in
                        NavigationLink {
                            LNBookListView(source: source, category: cat)
                        } label: {
                            card(cat)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ln.category.\(cat.rawValue)")
                    }
                }
                if let extraContent {
                    extraContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        // 与 NAS tab 一致：隐藏导航栏标题，只保留页面内大标题
        .navigationBarHidden(true)
        .refreshable { if showsCounts { await loadCounts() } }
        .task { if showsCounts { await loadCounts() } }
    }

    private func card(_ cat: LNCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: cat.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(ReadingTheme.accent)
            Text(cat.label)
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink)
            Text(showsCounts ? (counts[cat].map { "\($0) 本" } ?? "—") : "点按进入")
                .font(.caption)
                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(16)
        .background(ReadingTheme.groupedCanvas,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReadingTheme.separator.opacity(0.4), lineWidth: 0.5)
        }
    }

    private func loadCounts() async {
        isLoading = true
        defer { isLoading = false }
        var next: [LNCategory: Int] = [:]
        for cat in LNCategory.allCases {
            let path = source.categoryRoot(cat)
            guard let nodes = try? await source.list(at: path) else { continue }
            let books = try? await LNScanner.books(in: nodes, category: cat,
                                                    loadChildren: { node in
                                                        try await source.list(at: node.path)
                                                    })
            next[cat] = books?.count ?? 0
        }
        counts = next
    }
}

/// 书列表页：支持单选/多选删除
struct LNBookListView: View {
    let source: any LNLibrarySource
    let category: LNCategory

    @State private var books: [LNBook] = []
    @State private var errorMessage: String?
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<LNBook.ID> = []
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if books.isEmpty {
                ReadingUnavailableView("还没有\(category.label)",
                                       systemImage: category.symbol,
                                       description: Text(category.hint))
            } else {
                List(books, id: \.path, selection: $selected) { book in
                    NavigationLink {
                        LNChapterListView(source: source, book: book)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).foregroundStyle(.primary)
                            Text("\(book.chapters.count) 章")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await deleteBook(book) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle(category.label)
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if editMode == .active {
                    Button { cancelSelection() } label: {
                        Text("取消").accessibilityLabel("取消多选")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if editMode == .active {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash").accessibilityLabel("删除选中")
                    }
                    .disabled(selected.isEmpty)
                } else {
                    Button { editMode = .active } label: {
                        Text("选择").accessibilityLabel("进入多选模式")
                    }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert("读取失败", isPresented: Binding(get: { errorMessage != nil },
                                             set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("删除 \(selected.count) 部？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
        } message: {
            Text("将删除这些书的所有章节文件，不可恢复。")
        }
    }

    private func deleteSelected() async {
        let targets = books.filter { selected.contains($0.path) }
        for book in targets {
            try? await source.remove(at: book.path)
        }
        selected.removeAll()
        editMode = .inactive
        await load()
    }

    private func cancelSelection() {
        selected.removeAll()
        editMode = .inactive
    }

    private func deleteBook(_ book: LNBook) async {
        try? await source.remove(at: book.path)
        await load()
    }

    private func load() async {
        do {
            let nodes = try await source.list(at: source.categoryRoot(category))
            books = try await LNScanner.books(in: nodes, category: category,
                                               loadChildren: { node in
                                                   try await source.list(at: node.path)
                                               })
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            books = []
        }
    }
}

/// 章节列表页：支持单章删除与多选删除
struct LNChapterListView: View {
    let source: any LNLibrarySource
    let book: LNBook

    @State private var chapters: [LNChapter] = []
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<LNChapter.ID> = []
    @State private var confirmDelete = false
    @ObservedObject private var nav = LNReaderNavigation.shared
    @State private var showReader = false

    var body: some View {
        List(chapters, id: \.path, selection: $selected) { chapter in
            Button {
                nav.current = chapter
                showReader = true
            } label: {
                HStack {
                    Image(systemName: symbol(for: chapter.kind))
                        .foregroundStyle(ReadingTheme.accent)
                    Text(chapter.displayName).foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await deleteChapter(chapter) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .environment(\.editMode, $editMode)
        // 章末「下一章」：阅读页直接改 nav.current 原地换章（不退栈、无过渡），
        // 这里不再需要监听 token/dismiss——栈里始终只有一层阅读页，系统返回直接回目录。
        .readingNavigationDestination(isPresented: $showReader) {
            if let current = nav.current {
                LNReaderView(book: book, chapter: current, source: source, chapters: chapters)
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if editMode == .active {
                    Button { cancelSelection() } label: {
                        Text("取消").accessibilityLabel("取消多选")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if editMode == .active {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash").accessibilityLabel("删除选中章节")
                    }
                    .disabled(selected.isEmpty)
                } else {
                    Button { editMode = .active } label: {
                        Text("选择").accessibilityLabel("进入多选模式")
                    }
                }
            }
        }
        .task { chapters = book.chapters }
        .alert("删除 \(selected.count) 章？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
        } message: {
            Text("将删除这些章节文件，不可恢复。")
        }
    }

    private func deleteSelected() async {
        let targets = chapters.filter { selected.contains($0.path) }
        for chapter in targets {
            try? await source.remove(at: chapter.path)
        }
        chapters.removeAll { selected.contains($0.path) }
        selected.removeAll()
        editMode = .inactive
    }

    private func cancelSelection() {
        selected.removeAll()
        editMode = .inactive
    }

    private func deleteChapter(_ chapter: LNChapter) async {
        try? await source.remove(at: chapter.path)
        chapters.removeAll { $0.path == chapter.path }
    }

    private func symbol(for kind: LNChapterKind) -> String {
        switch kind {
        case .folder: return "folder"
        case .images: return "photo.on.rectangle"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        }
    }
}
