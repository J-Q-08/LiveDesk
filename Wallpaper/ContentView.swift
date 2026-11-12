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
    @State private var section: AppSection = .discover
    @State private var detailID: String?
    @State private var searchText = ""
    @State private var isGrid = true
    @State private var sortByName = false
    @State private var browseFilter: BrowseFilter = .all
    @State private var videoToDelete: LibraryVideo?
    @State private var confirmingPublicImport = false
    @State private var communityItems: [CommunityWallpaper] = []
    @State private var communityError: String?
    @State private var isLoadingCommunity = false
    @State private var communityHasMore = false
    @State private var isLoadingMoreCommunity = false
    @State private var isPublishing = false
    @State private var isDownloading = false
    @State private var didRestoreWallpaper = false
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var previewIsLoading = false
    @StateObject private var communityAuth = CommunityAuth.shared
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountPasswordConfirmation = ""
    @State private var accountMessage: String?
    @State private var isAuthenticating = false
    @State private var isCreatingAccount = false
    @AppStorage("selectedLibraryVideoID") private var selectedLibraryVideoID = ""
    @AppStorage("appliedVideoID") private var appliedVideoID = ""
    @AppStorage("appliedVideoLayout") private var appliedVideoLayout = "Fill"
    @AppStorage("launchAtLoginPreference") private var launchAtLoginPreference = true

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
            (searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)) &&
            (browseFilter == .all ||
             (browseFilter == .imports && item.id != "sample") ||
             (browseFilter == .sample && item.id == "sample") ||
             (browseFilter == .active && item.id == appliedVideoID))
        }
        return sortByName ? items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : items
    }

    private var searchedLibrary: [LibraryVideo] {
        library.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                Group {
                    if let detailID, let item = allItems.first(where: { $0.id == detailID }) {
                        detailView(item)
                    } else {
                        sectionView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            loadLibrary()
        }
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
                Task {
                    do {
                        let session = try await communityAuth.validSession()
                        let currentLibrary = library
                        let video = try await Task.detached(priority: .userInitiated) {
                            try VideoLibrary.importVideo(from: url, existing: currentLibrary)
                        }.value
                        library.append(video)
                        do {
                            let source = try VideoLibrary.url(for: video)
                            let item = try await CommunityService.publish(video: video, source: source, session: session)
                            library = try VideoLibrary.markPublished(video, communityID: item.id, existing: library)
                            videoError = nil
                            await loadCommunity()
                        } catch {
                            videoError = "Saved \(video.name) on this Mac, but sharing failed: \(error.localizedDescription). Retry below."
                        }
                        section = .submissions
                        detailID = nil
                    } catch {
                        videoError = "Couldn’t upload video: \(error.localizedDescription)"
                    }
                    isImporting = false
                }
            case .failure(let error):
                videoError = "Couldn’t select a video: \(error.localizedDescription)"
            }
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
            Text("The imported copy will be deleted. Your original file will stay where it is.")
        }
        .confirmationDialog("Share this video with everyone?", isPresented: $confirmingPublicImport) {
            Button("Choose Video to Share") { showVideoPicker = true }
        } message: {
            Text("The video you choose will be copied to this Mac and uploaded to Discover, where anyone can download it. Share only videos you have the right to publish.")
        }
        .task(id: "\(section.rawValue)|\(searchText)") {
            guard section == .discover else { return }
            while !Task.isCancelled {
                await loadCommunity()
                do { try await Task.sleep(for: .seconds(20)) }
                catch { break }
            }
        }
        .task(id: selectedVideo?.id) {
            previewIsLoading = true
            guard let url = selectedVideo?.url ?? Bundle.main.url(forResource: "sample", withExtension: "mp4") else {
                videoError = "Couldn’t find the bundled sample. Import a video to play."
                previewIsLoading = false
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
                previewIsLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                videoError = "Couldn’t play \(url.lastPathComponent): \(error.localizedDescription)"
                previewIsLoading = false
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
            if section == .library && detailID == nil {
                HStack(spacing: 2) {
                    Button { isGrid = true } label: { Image(systemName: "square.grid.2x2") }
                        .help("Grid view")
                    Button { isGrid = false } label: { Image(systemName: "rectangle.grid.1x2") }
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
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .help("Filter: \(browseFilter.rawValue)")
                    Menu {
                        Button("Recently added") { sortByName = false }
                        Button("Name") { sortByName = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                .buttonStyle(.borderless)
                .padding(7)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            if detailID == nil && section != .account {
                TextField("Search \(section.rawValue)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var sectionView: some View {
        switch section {
        case .discover:
            discoverView
        case .submissions:
            submissionsView
        case .library:
            libraryView
        case .account:
            accountView
        }
    }

    private var libraryView: some View {
        ScrollView {
            if isGrid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16)], spacing: 16) {
                    ForEach(libraryItems) { item in
                        wallpaperTile(item)
                    }
                }
                .padding(24)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(libraryItems) { item in
                        wallpaperTile(item).frame(maxWidth: 520)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .overlay {
            if libraryItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var discoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Community wallpapers").font(.title.bold())
                Text("Videos shared by the community. Select one to add it to your library.")
                    .foregroundStyle(.secondary)
                HStack {
                    if isLoadingCommunity { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await loadCommunity() } }
                }
                if let communityError {
                    Text(communityError).foregroundStyle(.red)
                }
                if communityItems.isEmpty && !isLoadingCommunity && communityError == nil {
                    ContentUnavailableView("No shared wallpapers yet", systemImage: "globe",
                                           description: Text("Publish a video from Submissions to make it appear here."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16)], spacing: 16) {
                        ForEach(communityItems) { item in
                            Button { download(item) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    AsyncImage(url: CommunityService.mediaURL(path: item.thumbnailPath)) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ZStack {
                                            Color.black
                                            Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(height: 190).clipped()
                                    Text(item.title).font(.headline).lineLimit(1).padding(12)
                                }
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(isDownloading)
                        }
                    }
                    if communityHasMore {
                        Button(isLoadingMoreCommunity ? "Loading…" : "Load More") {
                            Task { await loadMoreCommunity() }
                        }
                        .disabled(isLoadingMoreCommunity)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var submissionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your uploads").font(.title.bold())
                Text("Uploading a video adds a local copy to Library and shares it with everyone in Discover.")
                    .foregroundStyle(.secondary)
                if let session = communityAuth.session {
                    Label("Signed in as \(session.email)", systemImage: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Sign in or create an account to upload a video.")
                        Button("Sign In") { section = .account; isCreatingAccount = false }
                        Button("Create Account") { section = .account; isCreatingAccount = true }
                    }
                }
                if let videoError { Text(videoError).foregroundStyle(.red) }
                Button { confirmingPublicImport = true } label: {
                    Label(isImporting ? "Uploading…" : "Upload and Share Video", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || isPublishing || communityAuth.session == nil)
                if searchedLibrary.isEmpty {
                    ContentUnavailableView("No uploads yet", systemImage: "film.stack",
                                           description: Text(library.isEmpty
                                                             ? "Sign in and upload a video to share it."
                                                             : "No uploads match your search."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16)], spacing: 16) {
                        ForEach(searchedLibrary) { video in
                            if let item = allItems.first(where: { $0.id == video.id.uuidString }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    wallpaperTile(item)
                                    if video.communityID == nil {
                                        Button("Retry Sharing") { publish(video) }
                                            .disabled(isPublishing || communityAuth.session == nil)
                                            .help(communityAuth.session == nil ? "Sign in to retry sharing" : "Upload this local copy to Discover")
                                    } else {
                                        Label("Published", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                    .contextMenu {
                                        Button("Open Preview") { openDetail(item) }
                                        if video.communityID == nil {
                                            Button("Retry Sharing") { publish(video) }
                                                .disabled(isPublishing || communityAuth.session == nil)
                                        }
                                        Button("Remove from Library", role: .destructive) {
                                            videoToDelete = video
                                        }
                                        .disabled(appliedVideoID == video.id.uuidString)
                                    }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var accountView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Account").font(.largeTitle.bold())
                if let session = communityAuth.session {
                    Label("Signed in as \(session.email)", systemImage: "person.crop.circle.fill")
                        .font(.headline)
                    Text("You can upload and share videos from Submissions. Discover is available to everyone, including people who are signed out.")
                        .foregroundStyle(.secondary)
                    Button("Go to Submissions") { section = .submissions }
                        .buttonStyle(.borderedProminent)
                    Button("Sign Out") {
                        communityAuth.signOut()
                        accountMessage = "Signed out. You can still browse and download from Discover."
                    }
                } else {
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
                        Text("After creating an account, confirm your email, then return here to sign in.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(isCreatingAccount ? "Create Account" : "Sign In") {
                        authenticate(createAccount: isCreatingAccount)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)
                    if isAuthenticating { ProgressView() }
                }
                if let accountMessage {
                    Text(accountMessage).font(.callout)
                        .foregroundStyle(communityAuth.session == nil ? .secondary : .primary)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
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
                        ? "Account created. You can now upload from Submissions."
                        : "Account created. Check your email for a confirmation link, then return here and sign in."
                } else {
                    try await communityAuth.signIn(email: email, password: accountPassword)
                    accountMessage = "Signed in. You can now upload from Submissions."
                }
            } catch {
                accountMessage = "Account request failed: \(error.localizedDescription)"
            }
            accountPassword = ""
            accountPasswordConfirmation = ""
            isAuthenticating = false
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
            Button { detailID = nil } label: { Label("Back to Library", systemImage: "chevron.left") }
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
            if let videoError { Text(videoError).foregroundStyle(.red).font(.callout) }
        }
        .padding(24)
    }

    private func openDetail(_ item: WallpaperItem) {
        if item.id == "sample" { selectSample() }
        else if let video = library.first(where: { $0.id.uuidString == item.id }) { select(video) }
        detailID = item.id
    }

    private func loadCommunity() async {
        do {
            isLoadingCommunity = true
            communityItems = try await CommunityService.list(query: searchText)
            communityHasMore = communityItems.count == 50
            communityError = nil
        } catch {
            communityError = "Couldn’t load Discover: \(error.localizedDescription)"
        }
        isLoadingCommunity = false
    }

    private func loadMoreCommunity() async {
        guard !isLoadingMoreCommunity, communityHasMore else { return }
        isLoadingMoreCommunity = true
        do {
            let next = try await CommunityService.list(query: searchText, offset: communityItems.count)
            communityItems.append(contentsOf: next)
            communityHasMore = next.count == 50
            communityError = nil
        } catch {
            communityError = "Couldn’t load more wallpapers: \(error.localizedDescription)"
        }
        isLoadingMoreCommunity = false
    }

    private func publish(_ video: LibraryVideo) {
        guard !isPublishing else { return }
        isPublishing = true
        Task {
            do {
                let source = try VideoLibrary.url(for: video)
                let session = try await communityAuth.validSession()
                let item = try await CommunityService.publish(video: video, source: source, session: session)
                library = try VideoLibrary.markPublished(video, communityID: item.id,
                                                         existing: library)
                communityError = nil
                await loadCommunity()
            } catch {
                videoError = "Couldn’t publish \(video.name): \(error.localizedDescription)"
            }
            isPublishing = false
        }
    }

    private func download(_ item: CommunityWallpaper) {
        guard !isDownloading else { return }
        if let video = library.first(where: { $0.communityID == item.id }) {
            select(video)
            section = .library
            detailID = video.id.uuidString
            return
        }
        isDownloading = true
        Task {
            do {
                let video = try await CommunityService.download(wallpaper: item, existing: library)
                library.append(video)
                select(video)
                section = .library
                detailID = video.id.uuidString
                communityError = nil
            } catch {
                communityError = "Couldn’t download \(item.title): \(error.localizedDescription)"
            }
            isDownloading = false
        }
    }

    private func removeVideo(_ video: LibraryVideo) {
        guard appliedVideoID != video.id.uuidString else {
            videoError = "Change the active desktop wallpaper before removing this video."
            return
        }
        do {
            try VideoLibrary.remove(video, existing: library)
            library.removeAll { $0.id == video.id }
            if selectedLibraryVideoID == video.id.uuidString {
                selectSample()
                detailID = nil
            }
            videoError = nil
        } catch {
            videoError = "Couldn’t remove \(video.name): \(error.localizedDescription)"
        }
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
        previewIsLoading = true
        selectedLibraryVideoID = ""
        selectedVideo = nil
    }

    private func select(_ video: LibraryVideo) {
        do {
            previewIsLoading = true
            selectedVideo = VideoSelection(url: try VideoLibrary.url(for: video))
            selectedLibraryVideoID = video.id.uuidString
            videoError = nil
        } catch {
            previewIsLoading = false
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
    case submissions = "Submissions"
    case library = "Library"
    case account = "Account"

    var id: String { rawValue }
    var title: String { rawValue }
    var icon: String {
        switch self {
        case .discover: "star"
        case .submissions: "cloud"
        case .library: "books.vertical"
        case .account: "person.crop.circle"
        }
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

#Preview {
    ContentView()
}
