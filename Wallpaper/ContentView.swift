//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI
import AVFoundation
import AppKit
import Darwin
import UniformTypeIdentifiers
import ServiceManagement

struct ContentView: View {
    @State private var playback: VideoPlayback?
    @ObservedObject var desktop: DesktopWallpaperController
    @State private var showVideoPicker = false
    @State private var showUploadNameSheet = false
    @State private var pendingUploadURL: URL?
    @State private var pendingUploadAccount: CommunityAuth.PublishingAccount?
    @State private var uploadName = ""
    @State private var isImporting = false
    @State private var library: [LibraryVideo] = []
    @State private var videoError: String?
    @State private var videoLayout: VideoLayout = .fill
    @State private var displayConfiguration = 0
    @State private var section: AppSection = .discover
    @State private var showDiscoverFilters = false
    @State private var discoverFilters = DiscoverFilters()
    @State private var communityMedia: [String: CommunityMediaMetadata] = [:]
    @State private var metadataRefreshID = UUID()
    @State private var detailID: String?
    @State private var searches: [AppSection: String] = [:]
    @State private var isGrid = true
    @State private var sortByName = false
    @State private var browseFilter: BrowseFilter = .all
    @State private var videoToDelete: LibraryVideo?
    @State private var videoToRename: LibraryVideo?
    @State private var localName = ""
    @State private var libraryError: String?
    @State private var confirmingPublicImport = false
    @State private var communityItems: [CommunityWallpaper] = []
    @State private var communityQuery: String?
    @State private var communityRequestID: UUID?
    @State private var myCloudItems: [CommunityWallpaper] = []
    @State private var cloudError: String?
    @State private var cloudOwnerID: String?
    @State private var cloudRequestID: UUID?
    @State private var connectionStatus: ConnectionStatus = .checking
    @State private var communityError: String?
    @State private var isLoadingCommunity = false
    @State private var communityHasMore = false
    @State private var isLoadingMoreCommunity = false
    @State private var isPublishing = false
    @State private var downloadingTitle: String?
    @State private var downloadError: String?
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var previewError: String?
    @State private var isPreparingLockScreen = false
    @MainActor private static var isApplyingLockScreen = false
    @State private var lockScreenVideoID: String?
    @State private var lockScreenSetupItem: WallpaperItem?
    @State private var showLockScreenSetup = false
    @State private var showAerialSetup = false
    @AppStorage("lockScreenFolderBookmark") private var lockScreenFolderBookmark: Data?
    @StateObject private var communityAuth = CommunityAuth.shared
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountPasswordConfirmation = ""
    @State private var accountMessage: String?
    @State private var isAuthenticating = false
    @State private var isCreatingAccount = false
    @AppStorage("launchAtLoginPreference") private var launchAtLoginPreference = true

    private var trimmedLocalName: String { localName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchText: String { searches[section] ?? "" }
    private var searchBinding: Binding<String> {
        Binding(get: { searches[section] ?? "" }, set: { searches[section] = $0 })
    }

    private var allItems: [WallpaperItem] {
        let sample = Bundle.main.url(forResource: "sample", withExtension: "mp4")
            .map { [WallpaperItem(id: "sample", name: "Sample video", url: $0)] } ?? []
        let imports = library.compactMap { video -> WallpaperItem? in
            guard let url = try? VideoLibrary.url(for: video) else { return nil }
            return WallpaperItem(id: video.id.uuidString, name: video.name, url: url)
        }
        return sample + imports
    }

    private var libraryItems: [WallpaperItem] {
        let items = allItems.filter { item in
            matchesSearch(item.name) &&
            (browseFilter == .all ||
             (browseFilter == .imports && item.id != "sample") ||
             (browseFilter == .sample && item.id == "sample") ||
             (browseFilter == .active && item.id == desktop.appliedVideoID))
        }
        return sortByName ? items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : items
    }

    private var pendingUploads: [LibraryVideo] {
        library.filter { $0.communityID == nil }
    }

    private var searchedCloudUploads: [CommunityWallpaper] {
        guard cloudOwnerID == communityAuth.session?.userID else { return [] }
        return myCloudItems.filter { matchesSearch($0.title) }
    }

    private var isLoadingCloud: Bool { cloudRequestID != nil }

    private func matchesSearch(_ title: String) -> Bool {
        searchText.isEmpty || title.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    toolbar
                    if let downloadingTitle {
                        ProgressView("Downloading \(downloadingTitle)…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    }
                    if let downloadError {
                        HStack {
                            Label(downloadError, systemImage: "exclamationmark.circle")
                            Spacer()
                            Button("Dismiss") { self.downloadError = nil }
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                    if let libraryError {
                        HStack {
                            Label(libraryError, systemImage: "exclamationmark.circle")
                            Spacer()
                            Button("Dismiss") { self.libraryError = nil }
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                    Group {
                        if let detailID, let item = allItems.first(where: { $0.id == detailID }) {
                            detailView(item)
                        } else {
                            sectionView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                }
            }
            if !desktop.appliedVideoID.isEmpty { playbackBar }
        }
        .background { GalleryBackdrop() }
        .font(.custom("InterVariable", size: 13, relativeTo: .body))
        .preferredColorScheme(.dark)
        .tint(GalleryStyle.accent)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            loadLibrary()
            configureLoginItem()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = SMAppService.mainApp.status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayConfiguration += 1
        }
        .fileImporter(isPresented: $showVideoPicker, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url):
                pendingUploadURL = url
                uploadName = ""
                showUploadNameSheet = true
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    videoError = "Couldn’t select a video: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showUploadNameSheet, onDismiss: {
            pendingUploadURL = nil
            pendingUploadAccount = nil
            uploadName = ""
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name your wallpaper").font(.title2.bold())
                Text("This name will appear in your Library and in Discover for everyone.")
                    .foregroundStyle(.secondary)
                TextField("Wallpaper name", text: $uploadName)
                    .textFieldStyle(.roundedBorder)
                Text("\(uploadName.trimmingCharacters(in: .whitespacesAndNewlines).count)/100 characters")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showUploadNameSheet = false }
                    Button("Upload and Share") {
                        guard let url = pendingUploadURL, let account = pendingUploadAccount else { return }
                        let title = uploadName.trimmingCharacters(in: .whitespacesAndNewlines)
                        showUploadNameSheet = false
                        importAndShare(url: url, title: title, account: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingUploadURL == nil || uploadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              uploadName.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
        .alert("Set up Live Lock Screen", isPresented: $showLockScreenSetup,
               presenting: lockScreenSetupItem) { item in
            Button("Continue") { setLockScreen(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Allow LiveDesk to use the preselected wallpaper folder once. Click Allow Access in the next window. LiveDesk will then apply your video to the Lock Screen and the system wallpaper.")
        }
        .alert("Set up macOS Wallpaper", isPresented: $showAerialSetup) {
            Button("Open Wallpaper Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("In Wallpaper settings, download and select one of Apple’s moving wallpapers. Then return to LiveDesk and click Set as Live Lock Screen again.")
        }
        .alert("Rename Local Copy", isPresented: Binding(
            get: { videoToRename != nil },
            set: { if !$0 { videoToRename = nil } }
        )) {
            TextField("Wallpaper name", text: $localName)
            Button("Cancel", role: .cancel) { videoToRename = nil }
            Button("Rename") {
                if let videoToRename { renameVideo(videoToRename) }
                videoToRename = nil
            }
            .disabled(trimmedLocalName.isEmpty || trimmedLocalName.count > 100)
        } message: {
            Text("Choose a name of up to 100 characters. This changes the name in your Library on this Mac.")
        }
        .confirmationDialog("Remove video from library?", isPresented: Binding(
            get: { videoToDelete != nil },
            set: { if !$0 { videoToDelete = nil } }
        )) {
            Button("Remove Video", role: .destructive) {
                if let videoToDelete { removeVideo(videoToDelete) }
                videoToDelete = nil
            }
        } message: {
            Text("This deletes the copy on this Mac. Any original file and shared upload stay available.")
        }
        .confirmationDialog("Share this video with everyone?", isPresented: $confirmingPublicImport) {
            Button("Choose Video to Share") {
                do {
                    pendingUploadAccount = try communityAuth.publishingAccount()
                    showVideoPicker = true
                } catch {
                    videoError = error.localizedDescription
                }
            }
        } message: {
            Text("The video you choose will be copied to this Mac and uploaded to Discover, where anyone can download it. Share only videos you have the right to publish.")
        }
        .task(id: "\(section.rawValue)|\(searchText)") {
            guard section == .discover else { return }
            await loadCommunity(automatically: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) }
                catch { break }
                await loadCommunity(automatically: true)
            }
        }
        .task(id: communityAuth.session?.userID) {
            guard let userID = communityAuth.session?.userID else {
                cloudRequestID = nil
                cloudOwnerID = nil
                myCloudItems = []
                cloudError = nil
                return
            }
            await loadMyCloud(userID: userID)
        }
        .task {
            while !Task.isCancelled {
                await checkConnection()
                do { try await Task.sleep(for: .seconds(20)) }
                catch { break }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            if section == .library || section == .upload {
                sidebarSearch
                    .padding(.bottom, 14)
            }
            ForEach([AppSection.discover, .library, .upload]) { item in
                sidebarRow(item.rawValue, icon: item.icon, selected: section == item) {
                    section = item
                    detailID = nil
                }
            }
            Spacer()
            Divider().padding(.vertical, 4)
            if let error = desktop.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Label(connectionStatus.title, systemImage: connectionStatus.icon)
                .font(.caption)
                .foregroundStyle(connectionStatus == .connected ? Color.secondary : Color.orange)
                .help(connectionStatus == .connected ? "Connected to Supabase" : connectionStatus.title)
            Divider().padding(.vertical, 5)
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                set: { updateLaunchAtLogin($0) }
            ))
            .disabled(!isInstalledApp)
            if let loginItemMessage {
                Text(loginItemMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: 200)
        .background(.white.opacity(0.06))
        .overlay(alignment: .trailing) { Rectangle().fill(GalleryStyle.border).frame(width: 1).allowsHitTesting(false) }
    }

    private var sidebarSearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search \(section.rawValue)", text: searchBinding)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searches[section] = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 22, height: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? .white : GalleryStyle.accent)
                    .frame(width: 19)
                Text(title)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? .white : Color.white.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7).fill(GalleryStyle.background.opacity(0.52))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(GalleryStyle.border).allowsHitTesting(false) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var toolbar: some View {
        Group {
            if section == .discover && detailID == nil { discoverToolbar }
            else { sectionToolbar }
        }
    }

    private var sectionToolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detailID == nil ? section.title : "Wallpaper Preview")
                    .font(GalleryStyle.display(25)).tracking(-0.65)
                    .accessibilityAddTraits(.isHeader)
                if detailID == nil {
                    Text(section.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if section == .library && detailID == nil {
                HStack(spacing: 2) {
                    Button { isGrid = true } label: { layoutIcon("square.grid.2x2", selected: isGrid) }
                        .accessibilityLabel("Grid view")
                        .accessibilityAddTraits(isGrid ? .isSelected : [])
                        .help("Grid view")
                    Button { isGrid = false } label: { layoutIcon("rectangle.grid.1x2", selected: !isGrid) }
                        .accessibilityLabel("List view")
                        .accessibilityAddTraits(!isGrid ? .isSelected : [])
                        .help("List view")
                    Menu {
                        ForEach(BrowseFilter.allCases) { filter in
                            Button {
                                browseFilter = filter
                            } label: {
                                if browseFilter == filter { Label(filter.rawValue, systemImage: "checkmark") }
                                else { Text(filter.rawValue) }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 32, height: 32).contentShape(Rectangle()) }
                        .accessibilityLabel("Filter Library")
                        .help("Filter: \(browseFilter.rawValue)")
                    Menu {
                        Button("Recently added") { sortByName = false }
                        Button("Name") { sortByName = true }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 32, height: 32).contentShape(Rectangle()) }
                        .accessibilityLabel("Sort Library")
                        .help("Sort Library")
                }
                .buttonStyle(.borderless)
                .padding(2)
                .background(GalleryStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            }
            if section != .account { accountButton }
        }
        .padding(.horizontal, 24)
        .padding(.top, 13)
        .padding(.bottom, 16)
    }

    private var discoverToolbar: some View {
        HStack(spacing: 12) {
            Text("Discover")
                .font(GalleryStyle.display(25)).tracking(-0.65)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 14)
            sidebarSearch
                .frame(maxWidth: 440)
                .accessibilityIdentifier("discoverSearch")
            Button {
                communityMedia = communityMedia.filter { $0.value.dimensions != nil && $0.value.bytes != nil }
                metadataRefreshID = UUID()
                Task { await loadCommunity() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh Discover")
            .help("Refresh Discover")
            .disabled(isLoadingCommunity)
            accountButton
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var accountButton: some View {
        Button {
            section = .account
            detailID = nil
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 17))
                .frame(width: 32, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .help("Account")
    }

    private func layoutIcon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(selected ? GalleryStyle.accent : .secondary)
            .frame(width: 32, height: 32)
            .background(selected ? GalleryStyle.accent.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }

    private var playbackBar: some View {
        let item = allItems.first { $0.id == desktop.appliedVideoID }
        return ZStack(alignment: .leading) {
            HStack(spacing: 12) {
                if let item {
                    VideoThumbnail(url: item.url)
                        .frame(width: 54, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item?.name ?? "Desktop wallpaper")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(desktop.isDesktopPaused ? "Paused on all displays" : "All displays")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 330, alignment: .leading)
            HStack(spacing: 12) {
                Button {
                    desktop.setDesktopPaused(!desktop.isDesktopPaused)
                } label: {
                    Image(systemName: desktop.isDesktopPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(GalleryStyle.background)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.87), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(desktop.isDesktopPaused ? "Resume Wallpaper" : "Pause Wallpaper")
                .help(desktop.isDesktopPaused ? "Resume Wallpaper" : "Pause Wallpaper")
                .disabled(!desktop.canPause)
                .opacity(desktop.canPause ? 1 : 0.45)
                Button {
                    desktop.stop()
                    if browseFilter == .active { browseFilter = .all }
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Stop Wallpaper")
                .help("Stop Wallpaper")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .glassPanel(cornerRadius: 14)
        .padding(.horizontal, 12).padding(.bottom, 9).padding(.top, 4)
    }

    @ViewBuilder private var sectionView: some View {
        switch section {
        case .discover:
            discoverView
        case .upload:
            uploadView
        case .library:
            libraryView
        case .account:
            accountView
        }
    }

    private var libraryView: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 16
            let availableWidth = max(1, geometry.size.width - 48)
            let columnCount = max(1, Int((availableWidth + spacing) / (220 + spacing)))
            let columnWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
            let items = libraryItems
            ScrollView {
                if isGrid {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<min(columnCount, items.count), id: \.self) { column in
                            LazyVStack(spacing: spacing) {
                                let indices = stride(from: column, to: items.count, by: columnCount)
                                ForEach(indices.map { items[$0] }) { item in
                                    wallpaperTile(item, previewsOnHover: true)
                                }
                            }
                            .frame(width: columnWidth)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(items) { item in wallpaperTile(item, previewsOnHover: true) }
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var discoverView: some View {
        let items = communityQuery == searchText ? communityItems : []
        let filtersActive = discoverFilters.activeCount > 0
        let visibleItems = filtersActive ? items.filter { item in
            communityMedia[item.videoPath].map(discoverFilters.matches) ?? false
        } : items
        let checkingMetadata = filtersActive && items.contains { communityMedia[$0.videoPath] == nil }
        let missingMetadata = filtersActive && items.contains { item in
            communityMedia[item.videoPath].map { !discoverFilters.canEvaluate($0) } ?? false
        }

        return GeometryReader { geometry in
            let columnCount = max(1, Int((max(1, geometry.size.width - 48) + 16) / (220 + 16)))
            VStack(alignment: .leading, spacing: 14) {
                discoverFilterBar
                if checkingMetadata {
                    ProgressView("Checking wallpaper details…").controlSize(.small)
                }
                if missingMetadata && !checkingMetadata {
                    Text("Some wallpaper details are unavailable. Refresh to try again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let communityError {
                            Label(communityError, systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                            if items.isEmpty {
                                Button("Open Library") { section = .library }
                            }
                        }
                        if !visibleItems.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top),
                                                     count: columnCount), alignment: .leading, spacing: 24) {
                                ForEach(visibleItems) { item in communityTile(item, previewsOnHover: true) }
                            }
                        } else if communityQuery != searchText || isLoadingCommunity {
                            ProgressView("Loading wallpapers…").frame(maxWidth: .infinity, minHeight: 180)
                        } else if !checkingMetadata && communityError == nil {
                            ContentUnavailableView(filtersActive || !searchText.isEmpty ? "No matching wallpapers" : "No shared wallpapers yet",
                                                   systemImage: filtersActive || !searchText.isEmpty ? "magnifyingglass" : "globe",
                                                   description: filtersActive && communityHasMore
                                                       ? Text("Load more wallpapers to continue looking for matches.") : nil)
                                .frame(maxWidth: .infinity, minHeight: 180)
                        }
                        if communityQuery == searchText && communityHasMore {
                            Button(isLoadingMoreCommunity ? "Loading…" : "Load More") {
                                Task { await loadMoreCommunity() }
                            }
                            .disabled(isLoadingCommunity || isLoadingMoreCommunity)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                }
            }
            .padding(.horizontal, 24)
        }
        .task(id: [metadataRefreshID.uuidString] + (filtersActive ? items.map(\.videoPath) : [])) {
            guard filtersActive else { return }
            await inspectCommunityMedia(paths: items.map(\.videoPath))
        }
    }

    private var discoverFilterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    showDiscoverFilters.toggle()
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityValue(showDiscoverFilters ? "Expanded" : "Collapsed")
                if discoverFilters.activeCount > 0 {
                    Text("\(discoverFilters.activeCount) active").foregroundStyle(.secondary)
                    Button("Clear filters") { discoverFilters = DiscoverFilters() }
                        .buttonStyle(.plain).foregroundStyle(GalleryStyle.accent)
                }
            }
            if showDiscoverFilters {
                HStack(spacing: 22) {
                    Picker("Shape", selection: $discoverFilters.shape) {
                        ForEach(DiscoverFilters.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Resolution", selection: $discoverFilters.resolution) {
                        ForEach(DiscoverFilters.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .help("Resolution is grouped by the shorter side of the video.")
                    Picker("File size", selection: $discoverFilters.fileSize) {
                        ForEach(DiscoverFilters.FileSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 12)
    }

    private func inspectCommunityMedia(paths: [String]) async {
        let pending = paths.filter { communityMedia[$0] == nil }
        for offset in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = pending.dropFirst(offset).prefix(4)
            await withTaskGroup(of: (String, CommunityMediaMetadata).self) { group in
                for path in batch {
                    group.addTask { (path, await CommunityService.inspectMedia(path: path)) }
                }
                for await (path, metadata) in group {
                    if !Task.isCancelled { communityMedia[path] = metadata }
                }
            }
        }
    }

    private func localCopyURL(for item: CommunityWallpaper) -> URL? {
        for video in library where video.communityID == item.id {
            if let url = try? VideoLibrary.url(for: video) { return url }
        }
        return nil
    }

    private func communityTile(_ item: CommunityWallpaper, previewsOnHover: Bool = false) -> some View {
        let localURL = localCopyURL(for: item)
        let isLocal = localURL != nil
        let action = isLocal ? "Open in Library" : "Download to Library"
        let thumbnail = CommunityThumbnail(url: CommunityService.mediaURL(path: item.thumbnailPath))
        return Button { download(item) } label: {
            if previewsOnHover {
                HoverWallpaperTile(title: item.title, videoURL: localURL ?? CommunityService.mediaURL(path: item.videoPath)) {
                    thumbnail
                }
            } else {
                GalleryTile(title: item.title, symbol: isLocal ? "arrow.up.right" : "arrow.down",
                            subtitle: nil, captionsBelow: false) { thumbnail }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint(action)
        .help(action)
        .disabled(downloadingTitle != nil)
    }

    private var uploadView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Upload a wallpaper", systemImage: "square.and.arrow.up").font(GalleryStyle.display(25))
                    Text("Choose a video up to 50 MB. LiveDesk saves a local copy and shares it in Discover.")
                        .foregroundStyle(.secondary)
                    if communityAuth.isRestoring {
                        ProgressView("Restoring your sign-in…")
                    } else if let session = communityAuth.session {
                        Label("Signed in as \(session.email)", systemImage: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Sign in or create an account to upload a video.")
                            Button("Sign In") { section = .account; isCreatingAccount = false }
                            Button("Create Account") { section = .account; isCreatingAccount = true }
                        }
                    }
                    Button { confirmingPublicImport = true } label: {
                        Label(isImporting ? "Uploading…" : "Upload and Share Video", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(GlassActionStyle())
                    .disabled(isImporting || isPublishing || communityAuth.session == nil)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: 16)
                if let videoError { Text(videoError).foregroundStyle(.red) }
                if let cloudError, cloudOwnerID == communityAuth.session?.userID {
                    Text(cloudError).foregroundStyle(.orange)
                }
                if communityAuth.session != nil {
                    HStack {
                        Text("Your cloud uploads").font(.headline)
                        Spacer()
                        if isLoadingCloud { ProgressView().controlSize(.small) }
                        Button("Refresh") {
                            if let userID = communityAuth.session?.userID {
                                Task { await loadMyCloud(userID: userID) }
                            }
                        }
                        .disabled(isLoadingCloud)
                    }
                    if searchedCloudUploads.isEmpty && !isLoadingCloud && cloudError == nil {
                        Text(myCloudItems.isEmpty ? "No cloud uploads yet." : "No cloud uploads match your search.")
                            .foregroundStyle(.secondary)
                    } else if !searchedCloudUploads.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(searchedCloudUploads) { item in communityTile(item) }
                        }
                        Text("Select a cloud upload to open or download it to this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !pendingUploads.isEmpty {
                    Text("Waiting to share").font(.headline)
                    let matchingPending = pendingUploads.filter { matchesSearch($0.name) }
                    if matchingPending.isEmpty {
                        Text("No pending uploads match your search.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(matchingPending) { video in
                                if let item = allItems.first(where: { $0.id == video.id.uuidString }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        wallpaperTile(item)
                                        Button("Retry Sharing") { publish(video) }
                                            .disabled(isImporting || isPublishing || communityAuth.session == nil)
                                            .help(communityAuth.session == nil ? "Sign in to retry sharing" : "Upload this local copy to Discover")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    private var accountView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let session = communityAuth.session {
                    Label("Signed in as \(session.email)", systemImage: "person.crop.circle.fill")
                        .font(.headline)
                    Text("You can upload and share videos from the Upload section. Discover is available to everyone, including people who are signed out.")
                        .foregroundStyle(.secondary)
                    Button("Go to Upload") { section = .upload }
                        .buttonStyle(GlassActionStyle())
                    Button("Sign Out") {
                        Task {
                            do {
                                try await communityAuth.signOut()
                                accountMessage = "Signed out. You can still browse and download from Discover."
                            } catch {
                                accountMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(communityAuth.isSigningOut)
                } else {
                    if communityAuth.isRestoring { ProgressView("Restoring your sign-in…") }
                    if let restoreError = communityAuth.restoreError {
                        Text(restoreError).foregroundStyle(.orange)
                    }
                    Picker("Account action", selection: $isCreatingAccount) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    Text(isCreatingAccount ? "Create an account to upload videos to Discover." : "Sign in to upload videos to Discover.")
                        .foregroundStyle(.secondary)
                    TextField("Email address", text: $accountEmail)
                        .textContentType(.emailAddress)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $accountPassword)
                        .textContentType(isCreatingAccount ? .newPassword : .password)
                        .textFieldStyle(.roundedBorder)
                    if isCreatingAccount {
                        SecureField("Confirm password", text: $accountPasswordConfirmation)
                            .textContentType(.newPassword)
                            .textFieldStyle(.roundedBorder)
                        Text("Accounts are created immediately for this prototype. You can upload as soon as registration succeeds.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(isCreatingAccount ? "Create Account" : "Sign In") {
                        authenticate(createAccount: isCreatingAccount)
                    }
                    .buttonStyle(GlassActionStyle())
                    .disabled(isAuthenticating || communityAuth.isRestoring)
                    if isAuthenticating { ProgressView() }
                }
                if let accountMessage {
                    Text(accountMessage).font(.callout)
                        .foregroundStyle(communityAuth.session == nil ? .secondary : .primary)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(26)
            .glassPanel(cornerRadius: 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    private func authenticate(createAccount: Bool) {
        guard !isAuthenticating else { return }
        let email = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains("."), !accountPassword.isEmpty else {
            accountMessage = "Enter a valid email address and password."
            return
        }
        if createAccount {
            guard accountPassword.count >= 6 else {
                accountMessage = "Use a password with at least 6 characters."
                return
            }
            guard accountPassword == accountPasswordConfirmation else {
                accountMessage = "The passwords do not match."
                return
            }
        }
        isAuthenticating = true
        accountMessage = nil
        Task {
            do {
                if createAccount {
                    let signedIn = try await communityAuth.signUp(email: email, password: accountPassword)
                    accountMessage = signedIn
                        ? "Account created. You can now upload from the Upload section."
                        : "Account created, but sign-in is pending. Check your email, then return here and sign in."
                } else {
                    try await communityAuth.signIn(email: email, password: accountPassword)
                    accountMessage = "Signed in. You can now upload from the Upload section."
                }
            } catch {
                accountMessage = "Account request failed: \(error.localizedDescription)"
            }
            accountPassword = ""
            accountPasswordConfirmation = ""
            isAuthenticating = false
        }
    }

    private func wallpaperTile(_ item: WallpaperItem, previewsOnHover: Bool = false) -> some View {
        Button { openDetail(item) } label: {
            if previewsOnHover {
                HoverWallpaperTile(title: item.name, videoURL: item.url) {
                    VideoThumbnail(url: item.url)
                }
            } else {
                GalleryTile(title: item.name, symbol: "play.fill",
                            subtitle: desktop.appliedVideoID == item.id ? "Current wallpaper" : nil,
                            captionsBelow: true) {
                    VideoThumbnail(url: item.url)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityHint("Open wallpaper preview")
        .contextMenu {
            if let video = library.first(where: { $0.id.uuidString == item.id }) {
                localVideoActions(video)
            }
        }
    }

    @ViewBuilder
    private func localVideoActions(_ video: LibraryVideo) -> some View {
        Button("Rename Local Copy…") {
            localName = video.name
            videoToRename = video
        }
        Button("Remove from Library…", role: .destructive) {
            videoToDelete = video
        }
        .disabled(desktop.appliedVideoID == video.id.uuidString || isImporting || isPublishing)
    }

    private func detailView(_ item: WallpaperItem) -> some View {
        let currentPlayback = playback?.sourceURL == item.url ? playback : nil
        return VStack(alignment: .leading, spacing: 16) {
            Button { detailID = nil } label: {
                Label("Back to \(section.rawValue)", systemImage: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(GalleryStyle.accent)
            HStack(alignment: .top, spacing: 22) {
                VideoCanvas(player: currentPlayback?.previewPlayer, videoSize: currentPlayback?.videoSize ?? .zero,
                            videoLayout: videoLayout, isPreview: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(GalleryStyle.border).allowsHitTesting(false) }
                    .id("\(displayConfiguration)-\(currentPlayback?.id.uuidString ?? "none")")
                    .overlay {
                        if let previewError {
                            ContentUnavailableView("Preview unavailable", systemImage: "film", description: Text(previewError))
                        } else if currentPlayback == nil {
                            ProgressView("Loading preview…")
                        }
                    }
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.name)
                        .font(GalleryStyle.display(32)).tracking(-1.2)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Picker("Video layout", selection: $videoLayout) {
                        ForEach(VideoLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                    }
                    Button("Set as Desktop Background") { setDesktopBackground(item) }
                        .buttonStyle(GlassActionStyle()).disabled(currentPlayback == nil)
                    if section == .library {
                        Button(isPreparingLockScreen ? "Setting Lock Screen…" : "Set as Live Lock Screen") {
                            if lockScreenFolderBookmark == nil, #available(macOS 26.0, *) {
                                lockScreenSetupItem = item
                                showLockScreenSetup = true
                            } else {
                                setLockScreen(item)
                            }
                        }
                        .buttonStyle(GlassActionStyle())
                        .disabled(currentPlayback == nil || isPreparingLockScreen)
                        if lockScreenVideoID == item.id {
                            Label("Selected for Lock Screen", systemImage: "checkmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("Press Control–Command–Q to check your Lock Screen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Export Still Image…") { exportStillImage(from: item.url) }
                        .buttonStyle(.plain).foregroundStyle(GalleryStyle.accent)
                        .disabled(currentPlayback == nil)
                    if let video = library.first(where: { $0.id.uuidString == item.id }) {
                        Menu("Manage Local Copy") { localVideoActions(video) }
                            .fixedSize()
                    }
                    if let videoError { Text(videoError).foregroundStyle(.red).font(.callout) }
                }
                .padding(20)
                .frame(width: 270, alignment: .leading)
                .glassPanel(cornerRadius: 16)
            }
        }
        .padding(24)
        .task(id: item.id) {
            do {
                let next = try await VideoPlayback.load(item.url, requiresFileAccess: false)
                try Task.checkCancellation()
                guard detailID == item.id else { return }
                playback?.previewPlayer.pause()
                playback = next
                next.previewPlayer.play()
            } catch {
                guard !Task.isCancelled, detailID == item.id else { return }
                previewError = error.localizedDescription
            }
        }
        .onDisappear {
            playback?.previewPlayer.pause()
            playback = nil
        }
    }

    private func openDetail(_ item: WallpaperItem) {
        openDetail(id: item.id)
    }

    private func openDetail(id: String) {
        guard detailID != id else { return }
        playback?.previewPlayer.pause()
        playback = nil
        previewError = nil
        videoError = nil
        detailID = id
    }

    private func loadCommunity(automatically: Bool = false) async {
        guard section == .discover, !Task.isCancelled else { return }
        let query = searchText
        if communityQuery != query {
            communityItems = []
            communityError = nil
            communityHasMore = false
            communityQuery = query
        } else if automatically && (isLoadingCommunity || isLoadingMoreCommunity) {
            return
        }
        let previouslyLoadedCount = communityItems.count
        let requestID = UUID()
        communityRequestID = requestID
        isLoadingCommunity = true
        defer {
            if communityRequestID == requestID { isLoadingCommunity = false }
        }
        do {
            var page = try await CommunityService.list(query: query)
            guard !Task.isCancelled, section == .discover, query == searchText,
                  communityRequestID == requestID else { return }
            if automatically && previouslyLoadedCount > CommunityService.pageSize &&
                communityItems.prefix(CommunityService.pageSize).elementsEqual(page) {
                communityError = nil
                return
            }
            var items = page
            // Keep the loaded range visible and leave it intact if a request fails.
            while items.count < previouslyLoadedCount, page.count == CommunityService.pageSize,
                  let cursor = page.last {
                page = try await CommunityService.list(query: query, after: cursor)
                guard !Task.isCancelled, section == .discover, query == searchText,
                      communityRequestID == requestID else { return }
                items.append(contentsOf: page)
            }
            communityItems = items
            communityHasMore = page.count == CommunityService.pageSize
            communityError = nil
        } catch {
            guard !Task.isCancelled, section == .discover, query == searchText,
                  communityRequestID == requestID else { return }
            communityError = "Check your connection and try Refresh. Downloaded wallpapers are still available in Library."
        }
    }

    private func checkConnection() async {
        do {
            try await CommunityService.checkConnection()
            connectionStatus = .connected
        } catch {
            connectionStatus = connectionStatus(for: error)
        }
    }

    private func connectionStatus(for error: Error) -> ConnectionStatus {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
            return .offline
        }
        return .unavailable
    }

    private func loadMyCloud(userID: String) async {
        guard communityAuth.session?.userID == userID, !Task.isCancelled else { return }
        if cloudOwnerID != userID {
            myCloudItems = []
            cloudError = nil
            cloudOwnerID = userID
        }
        let requestID = UUID()
        cloudRequestID = requestID
        defer {
            if cloudRequestID == requestID { cloudRequestID = nil }
        }
        do {
            var found: [CommunityWallpaper] = []
            while true {
                let page = try await CommunityService.list(after: found.last, ownerID: userID)
                found.append(contentsOf: page)
                if page.count < CommunityService.pageSize { break }
                guard cloudRequestID == requestID else { return }
                try Task.checkCancellation()
            }
            guard !Task.isCancelled, cloudRequestID == requestID,
                  communityAuth.session?.userID == userID else { return }
            myCloudItems = found
            cloudError = nil
            connectionStatus = .connected
        } catch {
            guard !Task.isCancelled, cloudRequestID == requestID,
                  communityAuth.session?.userID == userID else { return }
            cloudError = "Couldn’t load your cloud uploads: \(error.localizedDescription)"
            connectionStatus = connectionStatus(for: error)
        }
    }

    private func loadMoreCommunity() async {
        guard !isLoadingCommunity, !isLoadingMoreCommunity, communityHasMore,
              let cursor = communityItems.last else { return }
        let query = searchText
        let requestID = communityRequestID
        isLoadingMoreCommunity = true
        defer { isLoadingMoreCommunity = false }
        do {
            let next = try await CommunityService.list(query: query, after: cursor)
            guard !Task.isCancelled, section == .discover, query == searchText,
                  communityRequestID == requestID else { return }
            communityItems.append(contentsOf: next)
            communityHasMore = next.count == CommunityService.pageSize
            communityError = nil
        } catch {
            guard !Task.isCancelled, section == .discover, query == searchText,
                  communityRequestID == requestID else { return }
            communityError = "Couldn’t load more wallpapers: \(error.localizedDescription)"
        }
    }

    private func importAndShare(url: URL, title: String, account: CommunityAuth.PublishingAccount) {
        guard !isImporting, !isPublishing, !title.isEmpty, title.count <= 100 else { return }
        isImporting = true
        videoError = nil
        Task {
            do {
                _ = try await communityAuth.validSession(for: account)
                let fileExtension = url.pathExtension
                let video = try await Task.detached(priority: .userInitiated) {
                    try await VideoLibrary.importVideo(from: url, extension: fileExtension, title: title)
                }.value
                library = try VideoLibrary.load()
                do {
                    let source = try VideoLibrary.url(for: video)
                    let item = try await CommunityService.publish(video: video, source: source, account: account)
                    library = try VideoLibrary.markPublished(video, communityID: item.id)
                    videoError = nil
                    await loadCommunity()
                    await loadMyCloud(userID: account.userID)
                } catch {
                    videoError = "Saved \(video.name) on this Mac, but sharing failed: \(error.localizedDescription). Retry below."
                }
                section = .upload
                detailID = nil
            } catch {
                videoError = "Couldn’t upload video: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func publish(_ video: LibraryVideo) {
        guard !isImporting, !isPublishing else { return }
        let account: CommunityAuth.PublishingAccount
        do {
            account = try communityAuth.publishingAccount()
        } catch {
            videoError = error.localizedDescription
            return
        }
        isPublishing = true
        videoError = nil
        Task {
            defer { isPublishing = false }
            do {
                let source = try VideoLibrary.url(for: video)
                try await VideoLibrary.validatePlayableVideo(source)
                let item = try await CommunityService.publish(video: video, source: source, account: account)
                library = try VideoLibrary.markPublished(video, communityID: item.id)
                await loadCommunity()
                await loadMyCloud(userID: account.userID)
            } catch {
                videoError = "Couldn’t publish \(video.name): \(error.localizedDescription)"
            }
        }
    }

    private func download(_ item: CommunityWallpaper) {
        guard downloadingTitle == nil else { return }
        downloadError = nil
        if let video = library.first(where: { $0.communityID == item.id && (try? VideoLibrary.url(for: $0)) != nil }) {
            section = .library
            openDetail(id: video.id.uuidString)
            return
        }
        let sourceSection = section
        downloadingTitle = item.title
        Task {
            defer { downloadingTitle = nil }
            do {
                let video = try await CommunityService.download(wallpaper: item)
                library = try VideoLibrary.load()
                if section == sourceSection, detailID == nil {
                    section = .library
                    openDetail(id: video.id.uuidString)
                }
            } catch {
                downloadError = "Couldn’t download \(item.title): \(error.localizedDescription)"
            }
        }
    }

    private func renameVideo(_ video: LibraryVideo) {
        let name = trimmedLocalName
        guard !name.isEmpty, name.count <= 100 else { return }
        do {
            library = try VideoLibrary.rename(video, to: name)
            libraryError = nil
        } catch {
            libraryError = "Couldn’t rename \(video.name): \(error.localizedDescription)"
        }
    }

    private func removeVideo(_ video: LibraryVideo) {
        guard desktop.appliedVideoID != video.id.uuidString else {
            libraryError = "Stop or change the active wallpaper before removing this video."
            return
        }
        guard !isImporting, !isPublishing else {
            libraryError = "Wait for sharing to finish before removing this video."
            return
        }
        do {
            library = try VideoLibrary.remove(video)
            if detailID == video.id.uuidString { detailID = nil }
            libraryError = nil
        } catch {
            libraryError = "Couldn’t remove \(video.name): \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        do {
            library = try VideoLibrary.load()
        } catch {
            libraryError = "Couldn’t load your video library: \(error.localizedDescription)"
        }
    }

    private func setDesktopBackground(_ item: WallpaperItem) {
        guard let playback, playback.sourceURL == item.url, detailID == item.id else { return }
        desktop.apply(playback, id: item.id, layout: videoLayout)
    }

    private func setLockScreen(_ item: WallpaperItem) {
        guard !isPreparingLockScreen, playback?.sourceURL == item.url, detailID == item.id else { return }
        guard #available(macOS 26.0, *), let home = Self.userHomeDirectory else {
            videoError = "Live Lock Screen requires macOS Tahoe or later."
            return
        }
        guard !Self.isApplyingLockScreen else {
            videoError = "LiveDesk is already setting a Lock Screen wallpaper."
            return
        }

        Self.isApplyingLockScreen = true
        isPreparingLockScreen = true
        videoError = nil
        Task {
            defer {
                Self.isApplyingLockScreen = false
                isPreparingLockScreen = false
            }
            do {
                let store = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper",
                                                        isDirectory: true)
                guard let (folder, startedAccess) = try await openLockScreenStore(at: store) else { return }
                defer { if startedAccess { folder.stopAccessingSecurityScopedResource() } }
                let assetID = try await LiveDeskAerialRegistrar.install(
                    videoURL: item.url, title: item.name, libraryID: item.id, in: folder)
                try await applyAerial(assetID, in: folder)
                lockScreenVideoID = item.id
            } catch LiveDeskAerialRegistrar.RegistrarError.manifestNotFound {
                showAerialSetup = true
            } catch {
                videoError = "Couldn’t set the live Lock Screen. \(error.localizedDescription)"
            }
        }
    }

    private func openLockScreenStore(at store: URL) async throws -> (URL, Bool)? {
        let storePath = store.resolvingSymlinksInPath().standardizedFileURL.path
        if let bookmark = lockScreenFolderBookmark {
            var stale = false
            if let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
               folder.resolvingSymlinksInPath().standardizedFileURL.path == storePath,
               folder.startAccessingSecurityScopedResource() {
                if stale, let refreshed = try? folder.bookmarkData(options: .withSecurityScope) {
                    lockScreenFolderBookmark = refreshed
                }
                return (folder, true)
            }
            lockScreenFolderBookmark = nil
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = store
        panel.prompt = "Allow Access"
        panel.message = "Click Allow Access with the wallpaper folder open. If you navigated away, press Shift–Command–G and enter ~/Library/Application Support/com.apple.wallpaper."
        guard await panel.begin() == .OK, let folder = panel.url else { return nil }
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == storePath else {
            throw LockScreenError.wrongFolder
        }
        let startedAccess = folder.startAccessingSecurityScopedResource()
        do {
            lockScreenFolderBookmark = try folder.bookmarkData(options: .withSecurityScope)
            return (folder, startedAccess)
        } catch {
            if startedAccess { folder.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func applyAerial(_ assetID: String, in store: URL) async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WallpaperRefresh.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let token = UUID()
        let requestFile = AerialSelection.requestURL(for: token, in: store)
        try Data(assetID.utf8).write(to: requestFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: requestFile) }
        guard let request = URL(string: "livedesk-wallpaper-refresh://\(token.uuidString)") else {
            throw LockScreenError.applyFailed
        }
        let app = try await NSWorkspace.shared.open([request], withApplicationAt: helper,
                                                    configuration: configuration)
        for _ in 0..<100 {
            if app.isTerminated {
                let index = try AerialSelection.readIndex(in: store)
                guard AerialSelection.selectedID(in: index) == assetID else { throw LockScreenError.applyFailed }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LockScreenError.applyFailed
    }

    private enum LockScreenError: LocalizedError {
        case wrongFolder, applyFailed

        var errorDescription: String? {
            switch self {
            case .wrongFolder:
                "Choose the com.apple.wallpaper folder in your Library’s Application Support folder."
            case .applyFailed:
                "macOS didn’t confirm the wallpaper change. Try again after closing Wallpaper settings."
            }
        }
    }

    private func exportStillImage(from url: URL) {
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

    private var isInstalledApp: Bool {
        let path = Bundle.main.bundleURL.path
        if path.hasPrefix("/Applications/") { return true }
        guard let home = Self.userHomeDirectory else { return false }
        return path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
    }

    private static let userHomeDirectory: URL? = {
        // Resolve the account's home from its Unix record because Foundation reports the sandbox home.
        let bufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: bufferSize > 0 ? bufferSize : 16_384)
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        return buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let directory = entry.pw_dir else { return nil }
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
    }()

    private var loginItemMessage: String? {
        if !isInstalledApp { return "Move LiveDesk to Applications to enable launch at login." }
        if let loginError { return loginError }
        if loginItemStatus == .requiresApproval {
            return "Approve LiveDesk in System Settings → Login Items."
        }
        return nil
    }

    private func configureLoginItem() {
        let service = SMAppService.mainApp
        loginItemStatus = service.status
        guard isInstalledApp, launchAtLoginPreference,
              loginItemStatus == .notRegistered || loginItemStatus == .notFound else { return }
        defer { loginItemStatus = service.status }
        do {
            try service.register()
            loginError = nil
        } catch {
            loginError = "Couldn’t enable launch at login: \(error.localizedDescription)"
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard isInstalledApp else { return }
        let service = SMAppService.mainApp
        defer { loginItemStatus = service.status }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            launchAtLoginPreference = enabled
            loginError = nil
        } catch {
            loginError = "Couldn’t change launch at login: \(error.localizedDescription)"
        }
    }
}

private enum ConnectionStatus {
    case checking, connected, offline, unavailable

    var title: String {
        switch self {
        case .checking: "Checking connection…"
        case .connected: "Connected"
        case .offline: "Offline — check your internet connection"
        case .unavailable: "Can’t reach Supabase"
        }
    }

    var icon: String {
        switch self {
        case .checking: "network"
        case .connected: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .unavailable: "wifi.exclamationmark"
        }
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case upload = "Upload"
    case library = "Library"
    case account = "Account"

    var id: String { rawValue }
    var title: String { rawValue }
    var subtitle: String {
        switch self {
        case .discover: "Wallpapers shared by the community"
        case .upload: "Share a video wallpaper to Discover"
        case .library: "Wallpapers saved on this Mac"
        case .account: "Manage your LiveDesk sign-in"
        }
    }
    var icon: String {
        switch self {
        case .discover: "star"
        case .upload: "cloud"
        case .library: "books.vertical"
        case .account: "person.crop.circle"
        }
    }
}

private struct GalleryTile<Artwork: View>: View {
    let title: String
    let symbol: String
    let subtitle: String?
    let captionsBelow: Bool
    @ViewBuilder let artwork: () -> Artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13)
        VStack(alignment: .leading, spacing: 8) {
            artwork()
                .overlay(alignment: .bottomLeading) {
                    if !captionsBelow {
                        caption
                            .padding(.top, 30).padding([.horizontal, .bottom], 12)
                            .background {
                                LinearGradient(colors: [.clear, GalleryStyle.background.opacity(0.94)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isHovered ? GalleryStyle.background : .white)
                        .frame(width: 31, height: 31)
                        .background(isHovered ? GalleryStyle.accent : .black.opacity(0.59), in: Circle())
                        .padding(9)
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(isHovered ? GalleryStyle.accent : GalleryStyle.border).allowsHitTesting(false) }
            if captionsBelow { caption.padding(.horizontal, 2) }
        }
        .contentShape(Rectangle())
        .offset(y: isHovered && !reduceMotion ? -3 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.72), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom("InterVariable", size: 13, relativeTo: .subheadline).weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(GalleryStyle.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum BrowseFilter: String, CaseIterable, Identifiable {
    case all = "All videos"
    case imports = "Imported videos"
    case sample = "Sample video"
    case active = "Active wallpaper"

    var id: String { rawValue }
}

private struct WallpaperItem: Identifiable {
    let id: String
    let name: String
    let url: URL
}

private struct VideoThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @State private var aspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1440, height: 1440)
            if let frame = try? await generator.image(at: .zero).image {
                image = NSImage(cgImage: frame, size: .zero)
                aspectRatio = CGFloat(frame.width) / CGFloat(frame.height)
            }
        }
    }
}

private struct CommunityThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var aspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        artwork.aspectRatio(aspectRatio, contentMode: .fit)
        .task(id: url) {
            image = nil
            aspectRatio = 16.0 / 9.0
            guard let url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return }
            self.image = image
            aspectRatio = image.size.width / image.size.height
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            ZStack {
                GalleryStyle.sidebar
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

#Preview {
    ContentView(desktop: DesktopWallpaperController())
}
