import AppKit
import AVFoundation
import AVKit

@MainActor
final class DemoController: NSWindowController, NSWindowDelegate {
    private let playerView = AVPlayerView()
    private let errorHeading = NSTextField(labelWithString: "Demo unavailable")
    private let errorMessage = NSTextField(wrappingLabelWithString: "")
    private let errorStack = NSStackView()
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var playbackError: String?
    private var preferredMuted = false
    private var preferredVolume: Float = 0.7

    init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
        let scale = min(1, max(1, visibleFrame.width - 64) / 960,
                        max(1, visibleFrame.height - titlebarHeight - 64) / 540)
        let contentSize = NSSize(width: floor(960 * scale), height: floor(540 * scale))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = "Codex Whip Demo"
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: min(480, contentSize.width), height: min(270, contentSize.height))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        let needsPlayback = player == nil && playbackError == nil
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if needsPlayback { startPlayback() }
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        if let player {
            preferredMuted = player.isMuted
            preferredVolume = player.volume
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player?.pause()
        player?.cancelPendingPrerolls()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        player = nil
        playbackError = nil
        errorStack.isHidden = true
        playerView.isHidden = false
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    // Read-only state for the isolated AppKit playback harness.
    var playbackSnapshot: [String: Any] {
        let item = player?.currentItem
        let status: String
        if playbackError != nil { status = "failed" }
        else if let item {
            switch item.status {
            case .unknown: status = "unknown"
            case .readyToPlay: status = "ready"
            case .failed: status = "failed"
            @unknown default: status = "unknown"
            }
        } else { status = "absent" }
        let currentTime = player?.currentTime().seconds ?? 0
        let duration = item?.duration.seconds
        return [
            "visible": window?.isVisible == true,
            "playerAttached": playerView.player != nil,
            "status": status,
            "timeSeconds": currentTime.isFinite ? currentTime : 0,
            "durationSeconds": duration.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull(),
            "rate": player?.rate ?? 0,
            "muted": player?.isMuted ?? preferredMuted,
            "volume": player?.volume ?? preferredVolume,
            "error": playbackError as Any? ?? NSNull(),
        ]
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.showsSharingServiceButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.allowsVideoFrameAnalysis = false
        playerView.setAccessibilityLabel("Codex Whip demo video")
        playerView.setAccessibilityHelp("Use the playback controls to pause, seek, replay, mute, or adjust the demo volume.")
        errorHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        errorHeading.alignment = .center
        errorMessage.alignment = .center
        errorMessage.textColor = .secondaryLabelColor
        errorMessage.maximumNumberOfLines = 0
        errorStack.orientation = .vertical
        errorStack.alignment = .centerX
        errorStack.spacing = 8
        errorStack.addArrangedSubview(errorHeading)
        errorStack.addArrangedSubview(errorMessage)
        errorStack.isHidden = true
        for view in [playerView, errorStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            errorStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            errorMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func startPlayback() {
        stop()
        guard let videoURL = Bundle.main.url(forResource: "Demo", withExtension: "mp4") else {
            showError("The bundled demo video is missing. Reinstall Codex Whip to watch it.")
            return
        }
        let item = AVPlayerItem(url: videoURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = preferredMuted
        player.volume = preferredVolume
        player.actionAtItemEnd = .pause
        self.player = player
        playerView.player = player
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player?.currentItem === item, item.status == .failed else { return }
                self.showError("The demo video couldn’t be played. Close and reopen this window to try again.")
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player?.currentItem === item else { return }
                self.showError("The demo video stopped unexpectedly. Close and reopen this window to try again.")
            }
        }
        player.play()
    }

    private func showError(_ message: String) {
        player?.pause()
        playbackError = message
        errorMessage.stringValue = message
        playerView.isHidden = true
        errorStack.isHidden = false
    }
}
