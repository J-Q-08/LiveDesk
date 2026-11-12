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
    @State private var desktopPlayers: [String: VideoPlayback] = [:]
    @State private var desktopWindows: [String: NSWindow] = [:]
    @State private var desktopGeneration = 0
    @State private var showVideoPicker = false
    @State private var showUploadNameSheet = false
    @State private var pendingUploadURL: URL?
    @State private var uploadName = ""
    @State private var isImporting = false
    @State private var library: [LibraryVideo] = []
    @State private var videoError: String?
    @State private var videoLayout: VideoLayout = .fill
    @State private var displayConfiguration = 0
    @State private var section: AppSection = .discover
    @State private var detailID: String?
    @State private var searches: [AppSection: String] = [:]
    @State private var isGrid = true
    @State private var sortByName = false
    @State private var browseFilter: BrowseFilter = .all
    @State private var videoToDelete: LibraryVideo?
    @State private var confirmingPublicImport = false
    @State private var communityItems: [CommunityWallpaper] = []
    @State private var myCloudItems: [CommunityWallpaper] = []
    @State private var cloudError: String?
    @State private var isLoadingCloud = false
    @State private var connectionStatus: ConnectionStatus = .checking
    @State private var communityError: String?
    @State private var isLoadingCommunity = false
    @State private var communityHasMore = false
    @State private var isLoadingMoreCommunity = false
    @State private var isPublishing = false
    @State private var downloadingTitle: String?
    @State private var downloadError: String?
    @State private var didRestoreWallpaper = false
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var previewError: String?
    @StateObject private var communityAuth = CommunityAuth.shared
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountPasswordConfirmation = ""
    @State private var accountMessage: String?
    @State private var isAuthenticating = false
    @State private var isCreatingAccount = false
    @AppStorage("appliedVideoID") private var appliedVideoID = ""
    @AppStorage("appliedVideoLayout") private var appliedVideoLayout = "Fill"
    @AppStorage("launchAtLoginPreference") private var launchAtLoginPreference = true

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
                Group {
                    if let detailID, let item = allItems.first(where: { $0.id == detailID }) {
                        detailView(item)
                    } else {
                        sectionView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            loadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayConfiguration += 1
            syncDesktopDisplays()
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
                        guard let url = pendingUploadURL else { return }
                        let title = uploadName.trimmingCharacters(in: .whitespacesAndNewlines)
                        showUploadNameSheet = false
                        importAndShare(url: url, title: title)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingUploadURL == nil || uploadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              uploadName.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
                }
            }
            .padding(24)
            .frame(width: 460)
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
        .task(id: communityAuth.session?.userID) {
            guard let userID = communityAuth.session?.userID else {
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
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label(connectionStatus.title, systemImage: connectionStatus.icon)
                .font(.caption)
                .foregroundStyle(connectionStatus == .connected ? Color.secondary : Color.orange)
                .help(connectionStatus == .connected ? "Connected to Supabase" : connectionStatus.title)
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
                    Button { isGrid = true } label: { Image(systemName: "square.grid.2x2").frame(width: 32, height: 32).contentShape(Rectangle()) }
                        .help("Grid view")
                    Button { isGrid = false } label: { Image(systemName: "rectangle.grid.1x2").frame(width: 32, height: 32).contentShape(Rectangle()) }
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
                        .help("Filter: \(browseFilter.rawValue)")
                    Menu {
                        Button("Recently added") { sortByName = false }
                        Button("Name") { sortByName = true }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 32, height: 32).contentShape(Rectangle()) }
                }
                .buttonStyle(.borderless)
                .padding(7)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            if detailID == nil && section != .account {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(section.rawValue)", text: searchBinding)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searches[section] = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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
            let columnCount = max(1, Int((max(1, geometry.size.width - 48) + 16) / (225 + 16)))
            ScrollView {
                if isGrid {
                    MasonryColumns(items: libraryItems, columnCount: columnCount) { item in
                        wallpaperTile(item)
                    }
                    .padding(24)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(libraryItems) { item in wallpaperTile(item) }
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                if libraryItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var discoverView: some View {
        GeometryReader { geometry in
            let columnCount = max(1, Int((max(1, geometry.size.width - 48) + 16) / (225 + 16)))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Community wallpapers").font(.title.bold())
                            Text("Videos shared by the community. Select one to add it to your Library.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isLoadingCommunity { ProgressView().controlSize(.small) }
                        Button("Refresh") { Task { await loadCommunity() } }
                    }
                    if let communityError {
                        Text(communityError).foregroundStyle(.red)
                    }
                    if communityItems.isEmpty && !isLoadingCommunity && communityError == nil {
                        ContentUnavailableView(searchText.isEmpty ? "No shared wallpapers yet" : "No matching wallpapers",
                                               systemImage: searchText.isEmpty ? "globe" : "magnifyingglass",
                                               description: Text(searchText.isEmpty
                                                                 ? "Upload a video to make it appear here."
                                                                 : "Try another search term."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        MasonryColumns(items: communityItems, columnCount: columnCount) { item in
                            communityTile(item)
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
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func communityTile(_ item: CommunityWallpaper) -> some View {
        Button { download(item) } label: {
            CommunityThumbnail(url: CommunityService.mediaURL(path: item.thumbnailPath))
                .overlay(alignment: .bottomLeading) { wallpaperTileTitle(item.title) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(downloadingTitle != nil)
    }

    private var uploadView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Uploading a video adds a local copy to Library and shares it with everyone in Discover.")
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
                if let videoError { Text(videoError).foregroundStyle(.red) }
                if let cloudError { Text(cloudError).foregroundStyle(.orange) }
                Button { confirmingPublicImport = true } label: {
                    Label(isImporting ? "Uploading…" : "Upload and Share Video", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || isPublishing || communityAuth.session == nil)
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
                    }
                    if myCloudItems.isEmpty && !isLoadingCloud && cloudError == nil {
                        Text("No videos uploaded to Supabase yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(myCloudItems) { item in communityTile(item) }
                        }
                    }
                    Text("Cloud uploads are available from any Mac. Select one to download a local copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("On this Mac").font(.headline)
                if searchedLibrary.isEmpty {
                    ContentUnavailableView("No uploads yet", systemImage: "film.stack",
                                           description: Text(library.isEmpty
                                                             ? "Sign in and upload a video to share it."
                                                             : "No uploads match your search."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16, alignment: .top)], spacing: 16) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    Text("You can upload and share videos from the Upload section. Discover is available to everyone, including people who are signed out.")
                        .foregroundStyle(.secondary)
                    Button("Go to Upload") { section = .upload }
                        .buttonStyle(.borderedProminent)
                    Button("Sign Out") {
                        Task {
                            await communityAuth.signOut()
                            accountMessage = "Signed out. You can still browse and download from Discover."
                        }
                    }
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
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating || communityAuth.isRestoring)
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

    private func wallpaperTile(_ item: WallpaperItem) -> some View {
        Button { openDetail(item) } label: {
            VideoThumbnail(url: item.url)
                .overlay(alignment: .bottomLeading) { wallpaperTileTitle(item.name) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func wallpaperTileTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                       startPoint: .top, endPoint: .bottom))
    }

    private func detailView(_ item: WallpaperItem) -> some View {
        let currentPlayback = playback?.sourceURL == item.url ? playback : nil
        return VStack(alignment: .leading, spacing: 18) {
            Button { detailID = nil } label: { Label("Back to \(section.rawValue)", systemImage: "chevron.left") }
                .buttonStyle(.plain)
            Text(item.name).font(.largeTitle.bold())
            VideoCanvas(player: currentPlayback?.previewPlayer, videoSize: currentPlayback?.videoSize ?? .zero,
                        videoLayout: videoLayout, isPreview: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .id("\(displayConfiguration)-\(currentPlayback?.id.uuidString ?? "none")")
                .overlay {
                    if let previewError {
                        ContentUnavailableView("Preview unavailable", systemImage: "film",
                                               description: Text(previewError))
                    } else if currentPlayback == nil {
                        ProgressView("Loading preview…")
                    }
                }
            HStack {
                Picker("Video layout", selection: $videoLayout) {
                    ForEach(VideoLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Export Still Image…") { exportStillImage(from: item.url) }
                    .disabled(currentPlayback == nil)
                Button("Set as Desktop Background") { setDesktopBackground(item) }
                    .buttonStyle(.borderedProminent).disabled(currentPlayback == nil)
            }
            if let videoError { Text(videoError).foregroundStyle(.red).font(.callout) }
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
        playback?.previewPlayer.pause()
        playback = nil
        previewError = nil
        videoError = nil
        detailID = id
    }

    private func loadCommunity() async {
        let query = searchText
        do {
            isLoadingCommunity = true
            let items = try await CommunityService.list(query: query)
            guard !Task.isCancelled, section == .discover, query == searchText else { return }
            communityItems = items
            communityHasMore = communityItems.count == 50
            communityError = nil
        } catch {
            guard !Task.isCancelled, section == .discover, query == searchText else { return }
            communityError = "Couldn’t load Discover: \(error.localizedDescription)"
        }
        isLoadingCommunity = false
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
        guard !isLoadingCloud else { return }
        isLoadingCloud = true
        defer { isLoadingCloud = false }
        do {
            var found: [CommunityWallpaper] = []
            while true {
                let page = try await CommunityService.list(offset: found.count, ownerID: userID)
                found.append(contentsOf: page)
                if page.count < 50 { break }
                try Task.checkCancellation()
            }
            guard communityAuth.session?.userID == userID else { return }
            myCloudItems = found
            cloudError = nil
            connectionStatus = .connected
        } catch {
            guard !Task.isCancelled else { return }
            cloudError = "Couldn’t load your cloud uploads: \(error.localizedDescription)"
            connectionStatus = connectionStatus(for: error)
        }
    }

    private func loadMoreCommunity() async {
        guard !isLoadingMoreCommunity, communityHasMore else { return }
        let query = searchText
        let offset = communityItems.count
        isLoadingMoreCommunity = true
        defer { isLoadingMoreCommunity = false }
        do {
            let next = try await CommunityService.list(query: query, offset: offset)
            guard !Task.isCancelled, section == .discover, query == searchText else { return }
            communityItems.append(contentsOf: next)
            communityHasMore = next.count == 50
            communityError = nil
        } catch {
            guard !Task.isCancelled, section == .discover, query == searchText else { return }
            communityError = "Couldn’t load more wallpapers: \(error.localizedDescription)"
        }
    }

    private func importAndShare(url: URL, title: String) {
        guard !isImporting, !title.isEmpty, title.count <= 100 else { return }
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            videoError = "Choose an MP4, MOV, or M4V video."
            return
        }
        isImporting = true
        videoError = nil
        Task {
            do {
                let session = try await communityAuth.validSession()
                let fileExtension = url.pathExtension
                let video = try await Task.detached(priority: .userInitiated) {
                    try VideoLibrary.validateForUpload(url)
                    return try VideoLibrary.importVideo(from: url, extension: fileExtension,
                                                        title: title)
                }.value
                library = try VideoLibrary.load()
                do {
                    let source = try VideoLibrary.url(for: video)
                    let item = try await CommunityService.publish(video: video, source: source, session: session)
                    library = try VideoLibrary.markPublished(video, communityID: item.id)
                    videoError = nil
                    await loadCommunity()
                    await loadMyCloud(userID: session.userID)
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
        guard !isPublishing else { return }
        isPublishing = true
        Task {
            do {
                let source = try VideoLibrary.url(for: video)
                let session = try await communityAuth.validSession()
                let item = try await CommunityService.publish(video: video, source: source, session: session)
                library = try VideoLibrary.markPublished(video, communityID: item.id)
                communityError = nil
                await loadCommunity()
                await loadMyCloud(userID: session.userID)
            } catch {
                videoError = "Couldn’t publish \(video.name): \(error.localizedDescription)"
            }
            isPublishing = false
        }
    }

    private func download(_ item: CommunityWallpaper) {
        guard downloadingTitle == nil else { return }
        downloadError = nil
        if let video = library.first(where: { $0.communityID == item.id }) {
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

    private func removeVideo(_ video: LibraryVideo) {
        guard appliedVideoID != video.id.uuidString else {
            videoError = "Change the active desktop wallpaper before removing this video."
            return
        }
        do {
            try VideoLibrary.remove(video)
            library = try VideoLibrary.load()
            if detailID == video.id.uuidString {
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
            configureLoginItem()
            if !didRestoreWallpaper {
                didRestoreWallpaper = true
                Task { await restoreDesktopBackground() }
            }
        } catch {
            videoError = "Couldn’t load your video library: \(error.localizedDescription)"
        }
    }

    private func setDesktopBackground(_ item: WallpaperItem) {
        guard let playback, playback.sourceURL == item.url, detailID == item.id else { return }
        applyDesktopBackground(playback, layout: videoLayout)
        appliedVideoID = item.id
        appliedVideoLayout = videoLayout.rawValue
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

    private func applyDesktopBackground(_ newPlayback: VideoPlayback, layout: VideoLayout) {
        desktopGeneration += 1
        let generation = desktopGeneration
        guard let primary = NSScreen.main ?? NSScreen.screens.first else { return }
        removeDisconnectedDisplays()
        installDesktopWindow(on: primary, playback: newPlayback, layout: layout)
        for screen in NSScreen.screens where screenID(screen) != screenID(primary) {
            loadDesktopWindow(on: screen, url: newPlayback.sourceURL, layout: layout, generation: generation)
        }
    }

    private func screenID(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return "\(screen.frame.origin.x),\(screen.frame.origin.y)"
    }

    private func installDesktopWindow(on screen: NSScreen, playback: VideoPlayback, layout: VideoLayout) {
        let id = screenID(screen)
        if let window = desktopWindows[id], let view = window.contentView as? VideoCanvasView {
            let previous = desktopPlayers[id]
            window.setFrame(screen.frame, display: true)
            view.configure(player: playback.desktopPlayer, videoSize: playback.videoSize,
                           layout: layout, isPreview: false)
            desktopPlayers[id] = playback
            playback.desktopPlayer.play()
            if previous !== playback { previous?.desktopPlayer.pause() }
            return
        }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        let videoView = VideoCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.autoresizingMask = [.width, .height]
        videoView.configure(player: playback.desktopPlayer, videoSize: playback.videoSize,
                            layout: layout, isPreview: false)
        window.contentView = videoView
        window.setFrame(screen.frame, display: true)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        desktopWindows[id] = window
        desktopPlayers[id] = playback
        playback.desktopPlayer.play()
        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)
        window.orderFront(nil)
    }

    private func loadDesktopWindow(on screen: NSScreen, url: URL, layout: VideoLayout, generation: Int) {
        let id = screenID(screen)
        Task {
            do {
                let player = try await VideoPlayback.load(url, requiresFileAccess: false)
                guard generation == desktopGeneration,
                      let connected = NSScreen.screens.first(where: { screenID($0) == id }) else { return }
                installDesktopWindow(on: connected, playback: player, layout: layout)
            } catch {
                guard generation == desktopGeneration else { return }
                videoError = "Couldn’t play the wallpaper on \(screen.localizedName): \(error.localizedDescription)"
            }
        }
    }

    private func removeDisconnectedDisplays() {
        let connected = Set(NSScreen.screens.map(screenID))
        for id in desktopWindows.keys.filter({ !connected.contains($0) }) {
            desktopPlayers[id]?.desktopPlayer.pause()
            desktopWindows[id]?.close()
            desktopPlayers.removeValue(forKey: id)
            desktopWindows.removeValue(forKey: id)
        }
    }

    private func syncDesktopDisplays() {
        guard let active = desktopPlayers.values.first else { return }
        removeDisconnectedDisplays()
        let layout = VideoLayout(rawValue: appliedVideoLayout) ?? .fill
        let generation = desktopGeneration
        for screen in NSScreen.screens {
            let id = screenID(screen)
            if let window = desktopWindows[id] {
                window.setFrame(screen.frame, display: true)
                (window.contentView as? VideoCanvasView)?.refreshGeometry()
            } else {
                loadDesktopWindow(on: screen, url: active.sourceURL, layout: layout, generation: generation)
            }
        }
    }

    private func restoreDesktopBackground() async {
        guard !appliedVideoID.isEmpty, desktopWindows.isEmpty else { return }
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
            guard desktopWindows.isEmpty else { return }
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
    var icon: String {
        switch self {
        case .discover: "star"
        case .upload: "cloud"
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
            guard let url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return }
            self.image = image
            aspectRatio = image.size.width / image.size.height
        }
    }
}

private struct MasonryColumns<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    let columnCount: Int
    let tile: (Item) -> Tile

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columnCount, id: \.self) { column in
                LazyVStack(spacing: 16) {
                    ForEach(columnItems(column)) { item in
                        tile(item)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func columnItems(_ column: Int) -> [Item] {
        items.enumerated().compactMap { index, item in
            index % columnCount == column ? item : nil
        }
    }
}

#Preview {
    ContentView()
}
