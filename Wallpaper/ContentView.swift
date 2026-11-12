//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI
import AVFoundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import ServiceManagement

struct ContentView: View {
    @State private var playback: VideoPlayback?
    @State private var desktopPlayback: VideoPlayback?
    @State private var desktopWindow: NSWindow?
    @State private var showVideoPicker = false
    @State private var isImporting = false
    @State private var selectedVideo: VideoSelection?
    @State private var library: [LibraryVideo] = []
    @State private var videoError: String?
    @State private var videoLayout: VideoLayout = .fill
    @State private var displayConfiguration = 0
    @State private var section: AppSection = .browse
    @State private var detailID: String?
    @State private var searchText = ""
    @State private var isGrid = true
    @State private var sortByName = false
    @State private var didRestoreWallpaper = false
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @AppStorage("selectedLibraryVideoID") private var selectedLibraryVideoID = ""
    @AppStorage("appliedVideoID") private var appliedVideoID = ""
    @AppStorage("appliedVideoLayout") private var appliedVideoLayout = "Fill"
    @AppStorage("launchAtLoginPreference") private var launchAtLoginPreference = true

    private var selectedName: String {
        library.first(where: { $0.id.uuidString == selectedLibraryVideoID })?.name ?? "Sample video"
    }

    private var browseItems: [WallpaperItem] {
        let sample = Bundle.main.url(forResource: "sample", withExtension: "mp4")
            .map { [WallpaperItem(id: "sample", name: "Sample video", url: $0)] } ?? []
        let imports = library.compactMap { video -> WallpaperItem? in
            guard let url = try? VideoLibrary.url(for: video) else { return nil }
            return WallpaperItem(id: video.id.uuidString, name: video.name, url: url)
        }
        let items = (sample + imports).filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return sortByName ? items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : items
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                Group {
                    if let detailID, let item = browseItems.first(where: { $0.id == detailID }) {
                        detailView(item)
                    } else {
                        sectionView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { loadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayConfiguration += 1
            guard let window = desktopWindow, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.frame, display: true)
            (window.contentView as? VideoCanvasView)?.refreshGeometry()
        }
        .fileImporter(isPresented: $showVideoPicker, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url):
                isImporting = true
                let currentLibrary = library
                Task {
                    do {
                        let video = try await Task.detached(priority: .userInitiated) {
                            try VideoLibrary.importVideo(from: url, existing: currentLibrary)
                        }.value
                        library.append(video)
                        select(video)
                        section = .browse
                        detailID = video.id.uuidString
                    } catch {
                        videoError = "Couldn’t import video: \(error.localizedDescription)"
                    }
                    isImporting = false
                }
            case .failure(let error):
                videoError = "Couldn’t select a video: \(error.localizedDescription)"
            }
        }
        .task(id: selectedVideo?.id) {
            guard let url = selectedVideo?.url ?? Bundle.main.url(forResource: "sample", withExtension: "mp4") else {
                videoError = "Couldn’t find the bundled sample. Import a video to play."
                return
            }
            do {
                let next = try await VideoPlayback.load(url, requiresFileAccess: false)
                try Task.checkCancellation()
                let previous = playback
                playback = next
                videoError = nil
                next.previewPlayer.play()
                previous?.previewPlayer.pause()
            } catch {
                guard !Task.isCancelled else { return }
                videoError = "Couldn’t play \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LiveDesk").font(.title2.bold()).padding(.horizontal, 14).padding(.bottom, 24)
            ForEach(AppSection.allCases) { item in
                Button {
                    section = item
                    detailID = nil
                } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(section == item ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { updateLaunchAtLogin($0) }
            ))
            .disabled(!isInstalledApp)
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 210)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(detailID == nil ? section.title : "Wallpaper Preview")
                .font(.title2.bold())
            Spacer()
            Button {
                showVideoPicker = true
            } label: {
                Label(isImporting ? "Importing…" : "Create", systemImage: "plus")
            }
            .disabled(isImporting)
            .buttonStyle(.bordered)
            if section == .browse && detailID == nil {
                HStack(spacing: 2) {
                    Button { isGrid = true } label: { Image(systemName: "square.grid.2x2") }
                        .help("Grid view")
                    Button { isGrid = false } label: { Image(systemName: "rectangle.grid.1x2") }
                        .help("List view")
                    Menu {
                        Button("All videos") { }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    Menu {
                        Button("Recently added") { sortByName = false }
                        Button("Name") { sortByName = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                .buttonStyle(.borderless)
                .padding(7)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var sectionView: some View {
        switch section {
        case .discover:
            Color.clear
        case .browse:
            browseView
        case .submissions:
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Your submissions").font(.title2.bold())
                Text("Import a video to add it to your local collection.").foregroundStyle(.secondary)
                Button("Import Video…") { showVideoPicker = true }
                    .buttonStyle(.borderedProminent).disabled(isImporting)
            }
        case .library:
            libraryView
        }
    }

    private var browseView: some View {
        ScrollView {
            if isGrid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16)], spacing: 16) {
                    ForEach(browseItems) { item in
                        wallpaperTile(item)
                    }
                }
                .padding(24)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(browseItems) { item in
                        wallpaperTile(item).frame(maxWidth: 520)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .overlay {
            if browseItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func wallpaperTile(_ item: WallpaperItem) -> some View {
        Button { openDetail(item) } label: {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    VideoThumbnail(url: item.url)
                        .frame(width: geometry.size.width, height: 220)
                        .clipped()
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                }
                .frame(width: geometry.size.width, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(height: 220)
        }
        .buttonStyle(.plain)
    }

    private func detailView(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { detailID = nil } label: { Label("Back to Browse", systemImage: "chevron.left") }
                .buttonStyle(.plain)
            Text(item.name).font(.largeTitle.bold())
            VideoCanvas(player: playback?.previewPlayer, videoSize: playback?.videoSize ?? .zero,
                        videoLayout: videoLayout, isPreview: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .id("\(displayConfiguration)-\(playback?.id.uuidString ?? "none")")
            HStack {
                Picker("Video layout", selection: $videoLayout) {
                    ForEach(VideoLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Export Still Image…") { exportStillImage() }
                Button("Set as Desktop Background") { setDesktopBackground() }
                    .buttonStyle(.borderedProminent).disabled(playback == nil)
            }
            Text("macOS does not support third-party video playback on the Lock Screen. Export a still frame to use in Wallpaper settings.")
                .font(.caption).foregroundStyle(.secondary)
            if let videoError { Text(videoError).foregroundStyle(.red).font(.callout) }
        }
        .padding(24)
    }

    private var libraryView: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("My videos").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        libraryRow("Sample video", selected: selectedLibraryVideoID.isEmpty) { selectSample() }
                        ForEach(library) { video in
                            libraryRow(video.name, selected: selectedLibraryVideoID == video.id.uuidString) {
                                select(video)
                            }
                        }
                    }
                }
                if library.isEmpty {
                    Text("Imported videos will appear here and remain available after you restart the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 240, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
                Text(selectedName).font(.headline).lineLimit(1)
                VideoCanvas(player: playback?.previewPlayer, videoSize: playback?.videoSize ?? .zero,
                            videoLayout: videoLayout, isPreview: true)
                    .frame(height: 290)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .id("\(displayConfiguration)-\(playback?.id.uuidString ?? "none")")
                Picker("Video layout", selection: $videoLayout) {
                    ForEach(VideoLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                }
                Button("Set as Desktop Background") { setDesktopBackground() }
                    .buttonStyle(.borderedProminent).disabled(playback == nil)
                Button("Export Still Image…") { exportStillImage() }
                if desktopWindow != nil {
                    Text("Video wallpaper is active on your desktop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let videoError { Text(videoError).foregroundStyle(.red).font(.callout) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
    }

    private func openDetail(_ item: WallpaperItem) {
        if item.id == "sample" { selectSample() }
        else if let video = library.first(where: { $0.id.uuidString == item.id }) { select(video) }
        detailID = item.id
    }

    private func libraryRow(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "film")
                Text(name).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func loadLibrary() {
        do {
            library = try VideoLibrary.load()
            if let video = library.first(where: { $0.id.uuidString == selectedLibraryVideoID }) {
                selectedVideo = VideoSelection(url: try VideoLibrary.url(for: video))
            } else {
                selectedLibraryVideoID = ""
            }
            configureLoginItem()
            if !didRestoreWallpaper {
                didRestoreWallpaper = true
                Task { await restoreDesktopBackground() }
            }
        } catch {
            videoError = "Couldn’t load your video library: \(error.localizedDescription)"
        }
    }

    private func selectSample() {
        selectedLibraryVideoID = ""
        selectedVideo = nil
    }

    private func select(_ video: LibraryVideo) {
        do {
            selectedVideo = VideoSelection(url: try VideoLibrary.url(for: video))
            selectedLibraryVideoID = video.id.uuidString
            videoError = nil
        } catch {
            videoError = "Couldn’t open \(video.name): \(error.localizedDescription)"
        }
    }

    private func setDesktopBackground() {
        guard let playback else { return }
        applyDesktopBackground(playback, layout: videoLayout)
        appliedVideoID = selectedLibraryVideoID.isEmpty ? "sample" : selectedLibraryVideoID
        appliedVideoLayout = videoLayout.rawValue
    }

    private func exportStillImage() {
        guard let url = selectedVideo?.url ?? Bundle.main.url(forResource: "sample", withExtension: "mp4") else { return }
        Task {
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                let frame = try await generator.image(at: .zero).image
                guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".png"
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try data.write(to: destination, options: .atomic)
            } catch {
                videoError = "Couldn’t export a still image: \(error.localizedDescription)"
            }
        }
    }

    private func applyDesktopBackground(_ newPlayback: VideoPlayback, layout: VideoLayout) {
        if let videoView = desktopWindow?.contentView as? VideoCanvasView {
            let previous = desktopPlayback
            videoView.configure(player: newPlayback.desktopPlayer, videoSize: newPlayback.videoSize,
                                layout: layout, isPreview: false)
            desktopPlayback = newPlayback
            newPlayback.desktopPlayer.play()
            if previous !== newPlayback { previous?.desktopPlayer.pause() }
            return
        }
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        let videoView = VideoCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.autoresizingMask = [.width, .height]
        videoView.configure(player: newPlayback.desktopPlayer, videoSize: newPlayback.videoSize,
                            layout: layout, isPreview: false)
        window.contentView = videoView
        window.setFrame(screen.frame, display: true)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        desktopWindow = window
        desktopPlayback = newPlayback
        newPlayback.desktopPlayer.play()
        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)
        window.orderFront(nil)
    }

    private func restoreDesktopBackground() async {
        guard !appliedVideoID.isEmpty, desktopWindow == nil else { return }
        let url: URL?
        if appliedVideoID == "sample" {
            url = Bundle.main.url(forResource: "sample", withExtension: "mp4")
        } else if let video = library.first(where: { $0.id.uuidString == appliedVideoID }) {
            url = try? VideoLibrary.url(for: video)
        } else {
            url = nil
        }
        guard let url else { return }
        do {
            let restored = try await VideoPlayback.load(url, requiresFileAccess: false)
            try Task.checkCancellation()
            guard desktopWindow == nil else { return }
            applyDesktopBackground(restored, layout: VideoLayout(rawValue: appliedVideoLayout) ?? .fill)
        } catch {
            videoError = "Couldn’t restore your desktop background: \(error.localizedDescription)"
        }
    }

    private var isInstalledApp: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func configureLoginItem() {
        let service = SMAppService.mainApp
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval
        guard isInstalledApp else {
            loginError = "Move LiveDesk to Applications to enable launch at login."
            return
        }
        guard launchAtLoginPreference, service.status == .notRegistered else { return }
        do {
            try service.register()
            launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            if service.status == .requiresApproval {
                loginError = "Approve LiveDesk in System Settings → Login Items."
            }
        } catch {
            loginError = "Couldn’t enable launch at login: \(error.localizedDescription)"
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard isInstalledApp else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginPreference = enabled
            launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve LiveDesk in System Settings → Login Items." : nil
        } catch {
            loginError = "Couldn’t change launch at login: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        }
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case browse = "Browse"
    case submissions = "Submissions"
    case library = "Library"

    var id: String { rawValue }
    var title: String { self == .browse ? "Browse All Backdrops" : rawValue }
    var icon: String {
        switch self {
        case .discover: "star"
        case .browse: "square.grid.2x2"
        case .submissions: "cloud"
        case .library: "books.vertical"
        }
    }
}

private struct WallpaperItem: Identifiable {
    let id: String
    let name: String
    let url: URL
}

private struct VideoThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            if let frame = try? await generator.image(at: .zero).image {
                image = NSImage(cgImage: frame, size: .zero)
            }
        }
    }
}

private struct LibraryVideo: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let filename: String
}

private enum VideoLibrary {
    nonisolated private static var directory: URL {
        get throws {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("LiveDesk/Videos", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    nonisolated private static var indexURL: URL {
        get throws { try directory.appendingPathComponent("library.json") }
    }

    nonisolated static func load() throws -> [LibraryVideo] {
        let index = try indexURL
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([LibraryVideo].self, from: Data(contentsOf: index))
    }

    nonisolated static func url(for video: LibraryVideo) throws -> URL {
        let file = try directory.appendingPathComponent(video.filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return file
    }

    nonisolated static func importVideo(from source: URL, existing: [LibraryVideo]) throws -> LibraryVideo {
        guard source.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { source.stopAccessingSecurityScopedResource() }
        let id = UUID()
        let filename = id.uuidString + "." + source.pathExtension.lowercased()
        let destination = try directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let video = LibraryVideo(id: id, name: source.deletingPathExtension().lastPathComponent,
                                     filename: filename)
            let data = try JSONEncoder().encode(existing + [video])
            try data.write(to: indexURL, options: .atomic)
            return video
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private enum VideoLayout: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    case stretch = "Stretch"
    case center = "Center"
    case tile = "Tile"

    var id: String { rawValue }
}

private struct VideoCanvas: NSViewRepresentable {
    let player: AVPlayer?
    let videoSize: CGSize
    let videoLayout: VideoLayout
    let isPreview: Bool

    func makeNSView(context: Context) -> VideoCanvasView { VideoCanvasView() }

    func updateNSView(_ view: VideoCanvasView, context: Context) {
        view.configure(player: player, videoSize: videoSize,
                       layout: videoLayout, isPreview: isPreview)
    }
}

private final class VideoCanvasView: NSView {
    private let verticalTiles = CAReplicatorLayer()
    private let horizontalTiles = CAReplicatorLayer()
    private let videoLayer = AVPlayerLayer()
    private var videoSize: CGSize = .zero
    private var videoLayout: VideoLayout = .fill
    private var isPreview = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(verticalTiles)
        verticalTiles.addSublayer(horizontalTiles)
        horizontalTiles.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(player: AVPlayer?, videoSize: CGSize, layout: VideoLayout, isPreview: Bool) {
        videoLayer.player = player
        self.videoSize = videoSize
        videoLayout = layout
        self.isPreview = isPreview
        updateGeometry()
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    func refreshGeometry() { updateGeometry() }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let screen = window?.screen ?? NSScreen.main
        let screenSize = screen?.frame.size ?? bounds.size
        let previewScale = isPreview
            ? min(bounds.width / screenSize.width, bounds.height / screenSize.height)
            : 1.0
        let canvasSize = isPreview
            ? CGSize(width: screenSize.width * previewScale, height: screenSize.height * previewScale)
            : bounds.size
        let canvas = CGRect(x: (bounds.width - canvasSize.width) / 2,
                            y: (bounds.height - canvasSize.height) / 2,
                            width: canvasSize.width, height: canvasSize.height)
        let screenScale = screen?.backingScaleFactor ?? 1.0
        let tileSize = CGSize(width: videoSize.width / screenScale * previewScale,
                              height: videoSize.height / screenScale * previewScale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        verticalTiles.frame = bounds
        horizontalTiles.frame = canvas
        verticalTiles.instanceCount = 1
        horizontalTiles.instanceCount = 1
        verticalTiles.instanceTransform = CATransform3DIdentity
        horizontalTiles.instanceTransform = CATransform3DIdentity

        switch videoLayout {
        case .fit:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            videoLayer.frame = horizontalTiles.bounds
            videoLayer.videoGravity = .resizeAspect
        case .fill:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            videoLayer.frame = horizontalTiles.bounds
            videoLayer.videoGravity = .resizeAspectFill
        case .stretch:
            // Use the view's full bounds so both axes match the display exactly.
            if videoLayer.superlayer !== layer {
                layer?.addSublayer(videoLayer)
            }
            videoLayer.frame = bounds
            videoLayer.videoGravity = .resize
        case .center, .tile:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            guard tileSize.width > 0, tileSize.height > 0 else {
                videoLayer.frame = .zero
                CATransaction.commit()
                return
            }
            videoLayer.videoGravity = .resize
            if videoLayout == .center {
                videoLayer.frame = CGRect(x: (canvas.width - tileSize.width) / 2,
                                          y: (canvas.height - tileSize.height) / 2,
                                          width: tileSize.width, height: tileSize.height)
            } else {
                let startX = (canvas.width - tileSize.width) / 2
                    - ceil(max(0, (canvas.width - tileSize.width) / 2) / tileSize.width) * tileSize.width
                let startY = (canvas.height - tileSize.height) / 2
                    - ceil(max(0, (canvas.height - tileSize.height) / 2) / tileSize.height) * tileSize.height
                videoLayer.frame = CGRect(origin: CGPoint(x: startX, y: startY), size: tileSize)
                horizontalTiles.instanceCount = max(1, Int(ceil((canvas.width - startX) / tileSize.width)))
                verticalTiles.instanceCount = max(1, Int(ceil((canvas.height - startY) / tileSize.height)))
                horizontalTiles.instanceTransform = CATransform3DMakeTranslation(tileSize.width, 0, 0)
                verticalTiles.instanceTransform = CATransform3DMakeTranslation(0, tileSize.height, 0)
            }
        }
        CATransaction.commit()
    }
}

private struct VideoSelection {
    let id = UUID()
    let url: URL
}

private final class VideoPlayback {
    let id = UUID()
    let previewPlayer: AVQueuePlayer
    let desktopPlayer: AVQueuePlayer
    let videoSize: CGSize
    private let previewLooper: AVPlayerLooper
    private let desktopLooper: AVPlayerLooper
    private let scopedURL: URL?

    private init(asset: AVURLAsset, videoSize: CGSize, scopedURL: URL?) {
        previewPlayer = AVQueuePlayer()
        desktopPlayer = AVQueuePlayer()
        previewPlayer.isMuted = true
        desktopPlayer.isMuted = true
        previewLooper = AVPlayerLooper(player: previewPlayer, templateItem: AVPlayerItem(asset: asset))
        desktopLooper = AVPlayerLooper(player: desktopPlayer, templateItem: AVPlayerItem(asset: asset))
        self.videoSize = videoSize
        self.scopedURL = scopedURL
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    static func load(_ url: URL, requiresFileAccess: Bool) async throws -> VideoPlayback {
        let scopedURL = requiresFileAccess ? url : nil
        if let scopedURL, !scopedURL.startAccessingSecurityScopedResource() {
            throw CocoaError(.fileReadNoPermission)
        }

        do {
            let asset = AVURLAsset(url: url)
            let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard isPlayable, duration.seconds.isFinite, duration.seconds > 0,
                  let track = tracks.first else {
                throw PlaybackError.unsupportedVideo
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let orientedSize = CGRect(origin: .zero, size: naturalSize).applying(transform).size
            let videoSize = CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height))
            guard videoSize.width > 0, videoSize.height > 0 else {
                throw PlaybackError.unsupportedVideo
            }
            try Task.checkCancellation()
            return VideoPlayback(asset: asset, videoSize: videoSize, scopedURL: scopedURL)
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private enum PlaybackError: LocalizedError {
        case unsupportedVideo

        var errorDescription: String? {
            "Choose a playable video with a video track."
        }
    }
}

#Preview {
    ContentView()
}
