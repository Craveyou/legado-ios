import SwiftUI

/// 分类入口视图：漫画 / 整理 / 短剧（本地），NAS 再加一个「电影」。
/// 本地 tab 与 NAS tab 的 CategoryView 复用同一个组件，只换 source 与 categories。
struct LNCategoryView: View {
    let source: any LNLibrarySource
    let title: String
    /// 说明文字：不传则不显示（本地 / 飞牛 NAS 分类页已去掉，
    /// 让标题位置与 NAS tab 完全一致）
    var subtitle: String? = nil
    /// 展示哪些分类。本地只有前三类，NAS 用 allCases（含电影）。
    var categories: [LNCategory] = LNCategory.localCases
    /// NAS 首屏不预统计（三类各一次远端探测会拖慢进入），进入分类时再加载
    var showsCounts: Bool = true

    @State private var counts: [LNCategory: Int] = [:]
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            // 水平内边距统一交给 header 内部的 24：
            // 之前外层又叠了 20，标题被多推右 20pt，与 NAS tab 错位、也和卡片不对齐。
            VStack(alignment: .leading, spacing: 0) {
                ReadingPageHeader(title: title, subtitle: subtitle) {
                    // 与 NAS tab 头部保持一致（NAS 用 + 添加连接）；
                    // 本地书库通过「文件」App 放书，这里用空操作占位保持视觉对称。
                    EmptyView()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(categories) { cat in
                        NavigationLink {
                            destination(for: cat)
                        } label: {
                            card(cat)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ln.category.\(cat.rawValue)")
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 30)
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        // 与 NAS tab 一致：隐藏导航栏标题，只保留页面内大标题
        .navigationBarHidden(true)
        .refreshable { if showsCounts { await loadCounts() } }
        .task { if showsCounts { await loadCounts() } }
    }

    /// 电影是平铺视频列表（点开即播），其余三类是「书 → 章」结构
    @ViewBuilder
    private func destination(for category: LNCategory) -> some View {
        if category == .movie {
            LNMovieListView(source: source)
        } else {
            LNBookListView(source: source, category: category)
        }
    }

    private func card(_ cat: LNCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: cat.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(ReadingTheme.accent)
            Text(cat.label)
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink)
            Text(showsCounts ? (counts[cat].map { "\($0) \(cat == .movie ? "部" : "本")" } ?? "—") : "点按进入")
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
        for cat in categories {
            let path = source.categoryRoot(cat)
            guard let nodes = try? await source.list(at: path) else { continue }
            if cat == .movie {
                // 电影目录下直接是视频文件，数量即条目数
                next[cat] = nodes.filter { LNScanner.isVideo($0) }.count
                continue
            }
            let books = try? await LNScanner.books(in: nodes, category: cat,
                                                    loadChildren: { node in
                                                        try await source.list(at: node.path)
                                                    })
            next[cat] = books?.count ?? 0
        }
        counts = next
    }
}

/// 电影海报墙：分类目录下直接是视频文件，同名图片做封面，点开即播。
/// 与其余三类不同——电影没有「书 → 章」结构，所以不走 LNScanner/LNBookListView。
///
/// 布局（用户口径）：竖版封面按 3 列走截图那种海报墙；横版封面一排两个。
/// 宽高比要先解码图片才知道，所以 load() 里把同名封面下载到本地、用 LNImageLoader
/// 解一次拿到比例，再按竖/横分组；分组只是排版，点击播放链路完全不变。
struct LNMovieListView: View {
    let source: any LNLibrarySource

    @State private var movies: [LNMediaItem] = []
    @State private var errorMessage: String?
    @State private var loading = false
    /// 视频 path → 已下载到本地的封面 URL（供海报格子显示）
    @State private var covers: [String: URL] = [:]
    /// 视频 path → 封面宽高比（宽/高）；<1 竖版，>=1 横版
    @State private var coverRatios: [String: CGFloat] = [:]

    /// 3 列竖版海报（截图样式）
    private let posterColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]
    /// 横版一排两个
    private let wideColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if loading && movies.isEmpty {
                posterSkeleton
            } else if let errorMessage, movies.isEmpty {
                ReadingUnavailableView("无法读取电影目录",
                                       systemImage: "film",
                                       description: Text(errorMessage))
            } else if movies.isEmpty {
                ReadingUnavailableView("还没有电影",
                                       systemImage: "film",
                                       description: Text(LNCategory.movie.hint))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !portraitMovies.isEmpty {
                            posterGrid(portraitMovies, columns: posterColumns)
                        }
                        if !landscapeMovies.isEmpty {
                            posterGrid(landscapeMovies, columns: wideColumns)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle(LNCategory.movie.label)
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
        .task { await load() }
        .refreshable { await load() }
        .accessibilityIdentifier("ln.movie.list")
    }

    /// 无封面 / 未知比例的视频都归竖版组（默认海报墙样式）
    private var portraitMovies: [LNMediaItem] {
        movies.filter { (coverRatios[$0.path] ?? 0.75) < 1 }
    }

    private var landscapeMovies: [LNMediaItem] {
        movies.filter { (coverRatios[$0.path] ?? 0.75) >= 1 }
    }

    private func posterGrid(_ items: [LNMediaItem], columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(items) { movie in
                NavigationLink {
                    LNMoviePlayerView(item: movie, source: source)
                } label: {
                    posterCell(movie)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放 \(movie.fileName)")
            }
        }
    }

    @ViewBuilder
    private func posterCell(_ movie: LNMediaItem) -> some View {
        let ratio = coverRatios[movie.path] ?? 0.75
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let cover = covers[movie.path],
                   let loaded = LNImageLoader.shared.cached(cover, maxPixel: 600) {
                    Image(uiImage: loaded.image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // 无封面：胶片占位（不依赖颜色单独传达，有图标）
                    ZStack {
                        ReadingTheme.groupedCanvas
                        Image(systemName: "film")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // 用 aspectRatio 而非固定高度：竖版高、横版扁，保留原始海报比例
            .aspectRatio(ratio > 0 ? ratio : 0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )

            Text(movie.fileName)
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink)
                .lineLimit(1)
                .accessibilityLabel(movie.fileName)
        }
    }

    private var posterSkeleton: some View {
        LazyVGrid(columns: posterColumns, spacing: 18) {
            ForEach(0 ..< 6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ReadingTheme.groupedCanvas)
                    .aspectRatio(0.75, contentMode: .fit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .redacted(reason: .placeholder)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let nodes = try await source.list(at: source.categoryRoot(.movie))
            let videos = nodes
                .filter { LNScanner.isVideo($0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            movies = videos.map { LNMediaItem(path: $0.path, fileName: $0.name, kind: .video) }

            // 同名封面匹配：去扩展名后完全一致（大小写不敏感），优先常见图片格式
            let images = nodes.filter { LNScanner.isImage($0) }
            var byBase: [String: LNNode] = [:]
            for image in images {
                let base = ((image.name as NSString).deletingPathExtension as NSString).lowercased
                if byBase[base] == nil { byBase[base] = image }
            }

            // 并发下载 + 解码封面（只取比例，LNImageLoader 会缓存解码结果）。
            // 串行 await 在 NAS 上是「每部电影一次列目录+一次下载」，几十部会卡很久。
            let loadedCovers = await withTaskGroup(of: (String, URL, CGFloat)?.self) { group in
                for video in videos {
                    let base = ((video.name as NSString).deletingPathExtension as NSString).lowercased
                    guard let coverNode = byBase[base] else { continue }
                    group.addTask {
                        guard let local = try? await source.localURL(for: coverNode.path) else { return nil }
                        guard let loaded = await LNImageLoader.shared.load(local, maxPixel: 600) else { return nil }
                        return (video.path, local, loaded.aspectRatio)
                    }
                }
                var results: [(String, URL, CGFloat)] = []
                for await item in group { if let item { results.append(item) } }
                return results
            }
            var nextCovers: [String: URL] = [:]
            var nextRatios: [String: CGFloat] = [:]
            for (path, local, ratio) in loadedCovers {
                nextCovers[path] = local
                nextRatios[path] = ratio
            }
            covers = nextCovers
            coverRatios = nextRatios
        } catch {
            // 只显示 SMB 错误码用户看不出在哪改，把实际探测路径一起报出来
            let path = source.categoryRoot(.movie)
            errorMessage = "读取目录 \(path) 失败：\(error.localizedDescription)\n\n到 NAS 连接编辑页检查「电影」分类目录，或直接用浏览按钮选一个实际存在的文件夹。"
        }
    }
}

/// 电影播放页：全宽 16:9 播放器，点播放按钮即自动全屏（LNVideoView 内置行为）。
struct LNMoviePlayerView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // playerHeight 传 nil：按 16:9 自适应宽度，电影画面比章内小卡片大得多
                LNVideoView(item: item, source: source, playerHeight: nil)
                Text("建议横屏或点右上角全屏观看；缓存过的片段下次打开会更快。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationTitle(item.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
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
                // 同章节列表：不用 List(selection:)，否则整行点击只会选中不进入（b60 修复）
                List(books, id: \.path) { book in
                    if editMode == .active {
                        Button {
                            toggleSelection(book)
                        } label: {
                            bookRow(book)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            LNChapterListView(source: source, book: book)
                        } label: {
                            bookRow(book)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await deleteBook(book) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
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

    /// 书籍行内容：多选模式显示勾选圈；整行 contentShape 保证空白处可点
    private func bookRow(_ book: LNBook) -> some View {
        HStack(spacing: 10) {
            if editMode == .active {
                Image(systemName: selected.contains(book.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(book.path)
                                     ? ReadingTheme.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).foregroundStyle(.primary)
                Text("\(book.chapters.count) 章")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func toggleSelection(_ book: LNBook) {
        if selected.contains(book.path) {
            selected.remove(book.path)
        } else {
            selected.insert(book.path)
        }
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
        // 注意：这里**不能用** List(selection:)。带 selection 绑定的 List 会一直处于
        // 选择模式，点击整行只是「选中高亮」，不会触发行内的 Button/NavigationLink——
        // 表现为只有点在文字上才能进章节、点同行空白处只出现高亮（b60 修复）。
        // 现在改成：普通模式 = 整行可点的按钮；多选模式 = 手动勾选（自绘 checkmark）。
        List(chapters, id: \.path) { chapter in
            if editMode == .active {
                Button {
                    toggleSelection(chapter)
                } label: {
                    chapterRow(chapter)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    nav.current = chapter
                    showReader = true
                } label: {
                    chapterRow(chapter)
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
        }
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

    /// 章节行内容：整行 .contentShape(Rectangle()) 保证空白处也可点；
    /// 多选模式下左侧显示勾选圈。
    private func chapterRow(_ chapter: LNChapter) -> some View {
        HStack(spacing: 10) {
            if editMode == .active {
                Image(systemName: selected.contains(chapter.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(chapter.path)
                                     ? ReadingTheme.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            Image(systemName: symbol(for: chapter.kind))
                .foregroundStyle(ReadingTheme.accent)
            Text(chapter.displayName).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        // 关键：把点击区域扩到整行（含右侧空白）
        .contentShape(Rectangle())
    }

    private func toggleSelection(_ chapter: LNChapter) {
        if selected.contains(chapter.path) {
            selected.remove(chapter.path)
        } else {
            selected.insert(chapter.path)
        }
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
