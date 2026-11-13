import AppKit
import AVFoundation
import Combine
import CoreGraphics

@MainActor
final class DesktopWallpaperController: ObservableObject {
    @Published private(set) var appliedVideoID = UserDefaults.standard.string(forKey: "appliedVideoID") ?? ""
    @Published private(set) var isDesktopPaused = false
    @Published private(set) var error: String?
    @Published private var desktopTarget: (url: URL, layout: VideoLayout)?

    private var desktopPlayers: [String: VideoPlayback] = [:]
    private var desktopWindows: [String: NSWindow] = [:]
    private var desktopGeneration = 0
    private var loadingDisplays: Set<String> = []
    private var didRestore = false
    private var displayObserver: AnyCancellable?

    var canPause: Bool { desktopTarget != nil }

    init() {
        displayObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncDesktopDisplays() }
            }
    }

    func apply(_ playback: VideoPlayback, id: String, layout: VideoLayout) {
        error = nil
        isDesktopPaused = false
        applyDesktopBackground(playback, layout: layout)
        appliedVideoID = id
        UserDefaults.standard.set(id, forKey: "appliedVideoID")
        UserDefaults.standard.set(layout.rawValue, forKey: "appliedVideoLayout")
    }

    func setDesktopPaused(_ paused: Bool) {
        isDesktopPaused = paused
        for playback in desktopPlayers.values {
            updateDesktopPlayback(playback)
        }
    }

    private func updateDesktopPlayback(_ playback: VideoPlayback) {
        if isDesktopPaused {
            playback.desktopPlayer.pause()
        } else {
            playback.desktopPlayer.play()
        }
    }

    func stop() {
        desktopGeneration += 1
        desktopTarget = nil
        loadingDisplays.removeAll()
        setDesktopPaused(true)
        for window in desktopWindows.values {
            window.close()
        }
        desktopWindows.removeAll()
        desktopPlayers.removeAll()
        isDesktopPaused = false
        appliedVideoID = ""
        UserDefaults.standard.removeObject(forKey: "appliedVideoID")
        error = nil
    }

    private func applyDesktopBackground(_ newPlayback: VideoPlayback, layout: VideoLayout) {
        desktopGeneration += 1
        desktopTarget = (newPlayback.sourceURL, layout)
        loadingDisplays.removeAll()
        if let primary = NSScreen.main ?? NSScreen.screens.first {
            installDesktopWindow(on: primary, playback: newPlayback, layout: layout)
        }
        syncDesktopDisplays()
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
                           layout: layout, isPreview: false, desktopBackingScale: screen.backingScaleFactor)
            desktopPlayers[id] = playback
            updateDesktopPlayback(playback)
            if previous !== playback { previous?.desktopPlayer.pause() }
            return
        }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        let videoView = VideoCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.autoresizingMask = [.width, .height]
        videoView.configure(player: playback.desktopPlayer, videoSize: playback.videoSize,
                            layout: layout, isPreview: false, desktopBackingScale: screen.backingScaleFactor)
        window.contentView = videoView
        window.setFrame(screen.frame, display: true)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        desktopWindows[id] = window
        desktopPlayers[id] = playback
        updateDesktopPlayback(playback)
        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)
        window.orderFront(nil)
    }

    private func loadDesktopWindow(on screen: NSScreen, url: URL, layout: VideoLayout, generation: Int) {
        let id = screenID(screen)
        guard loadingDisplays.insert(id).inserted else { return }
        Task {
            defer {
                if generation == desktopGeneration { loadingDisplays.remove(id) }
            }
            do {
                let player = try await VideoPlayback.load(url, requiresFileAccess: false)
                guard generation == desktopGeneration,
                      let connected = NSScreen.screens.first(where: { screenID($0) == id }) else { return }
                installDesktopWindow(on: connected, playback: player, layout: layout)
            } catch {
                guard generation == desktopGeneration,
                      NSScreen.screens.contains(where: { screenID($0) == id }) else { return }
                self.error = "Couldn’t play the wallpaper on \(screen.localizedName): \(error.localizedDescription)"
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
        guard let target = desktopTarget else { return }
        removeDisconnectedDisplays()
        for screen in NSScreen.screens {
            let id = screenID(screen)
            if let playback = desktopPlayers[id], playback.sourceURL == target.url {
                installDesktopWindow(on: screen, playback: playback, layout: target.layout)
            } else {
                loadDesktopWindow(on: screen, url: target.url, layout: target.layout,
                                  generation: desktopGeneration)
            }
        }
    }

    func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard !appliedVideoID.isEmpty else { return }
        Task { await restore() }
    }

    private func restore() async {
        guard !appliedVideoID.isEmpty, desktopTarget == nil else { return }
        let generation = desktopGeneration
        do {
            let url: URL?
            if appliedVideoID == "sample" {
                url = Bundle.main.url(forResource: "sample", withExtension: "mp4")
            } else {
                let video = try VideoLibrary.load().first { $0.id.uuidString == appliedVideoID }
                url = try video.map { try VideoLibrary.url(for: $0) }
            }
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let restored = try await VideoPlayback.load(url, requiresFileAccess: false)
            try Task.checkCancellation()
            guard generation == desktopGeneration else { return }
            let layoutName = UserDefaults.standard.string(forKey: "appliedVideoLayout") ?? ""
            applyDesktopBackground(restored, layout: VideoLayout(rawValue: layoutName) ?? .fill)
        } catch {
            guard !Task.isCancelled, generation == desktopGeneration else { return }
            self.error = "Couldn’t restore your desktop background: \(error.localizedDescription)"
        }
    }
}
