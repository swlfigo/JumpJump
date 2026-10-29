import UIKit
import RealityKit

// Own the touch stream in a plain UIKit view, not inside ARView's input system.
// The HUD/buttons are above this transparent surface and keep their own input.
final class GameInputView: UIView {
    var began: (() -> Void)?
    var ended: (() -> Void)?
    var cancelled: (() -> Void)?
    private var activeTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        began?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        ended?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        cancelled?()
    }
    func cancelActiveTouch() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        cancelled?()
    }
}

// Holds the in-game HUD so it can be shown or hidden as one; touches that miss
// its controls fall through to the play area below.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// Non-interactive HUD: green band is the conservative landing range,
// dark tick is the center target, blue fill is the user's live charge.
final class ForceMeterView: UIView {
    var progress: Float = 0 { didSet { if oldValue != progress { refresh() } } }
    var guide: ForceGuide? { didSet { if oldValue != guide { refresh() } } }
    private func refresh() {
        setNeedsDisplay()
        guard let guide else { return }
        let full = ForceGuide.fullChargeDuration
        accessibilityValue = String(format: "current=%.5f;ideal=%.5f;minimum=%.5f;maximum=%.5f;seconds=%.5f;targetID=%d", progress, guide.idealSeconds / full, guide.minimumSeconds / full, guide.maximumSeconds / full, guide.idealSeconds, guide.targetID)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let track = CGRect(x: 1, y: 4, width: bounds.width - 2, height: 8)
        let path = UIBezierPath(roundedRect: track, cornerRadius: 4)
        UIColor(hex: 0xD5D7D1).setFill(); path.fill()
        context.saveGState(); path.addClip()
        UIColor(hex: 0x75A4C7).setFill()
        context.fill(CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(max(0, min(progress, 1))), height: track.height))
        if let guide {
            let full = ForceGuide.fullChargeDuration
            let lower = CGFloat(max(0, min(guide.minimumSeconds / full, 1)))
            let upper = CGFloat(max(0, min(guide.maximumSeconds / full, 1)))
            UIColor(hex: 0x62B88A).withAlphaComponent(0.65).setFill()
            context.fill(CGRect(x: track.minX + track.width * lower, y: track.minY, width: track.width * (upper - lower), height: track.height))
        }
        context.restoreGState()
        if let guide {
            let ideal = CGFloat(max(0, min(guide.idealSeconds / ForceGuide.fullChargeDuration, 1)))
            let x = track.minX + track.width * ideal
            context.setStrokeColor(UIColor(hex: 0x294E3E).cgColor)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: x, y: 1)); context.addLine(to: CGPoint(x: x, y: 15)); context.strokePath()
        }
        let currentX = track.minX + track.width * CGFloat(max(0, min(progress, 1)))
        UIColor(hex: 0x28689A).setFill()
        UIBezierPath(ovalIn: CGRect(x: currentX - 3, y: 5, width: 6, height: 6)).fill()
    }
}

final class GameViewController: UIViewController {
    private var gameView: ARView!
    private let playInputView = GameInputView()
    private var game: GameRenderer!
    private let scoreLabel = UILabel()
    private let bestLabel = UILabel()
    private let messageLabel = UILabel()
    private let floatingScoreLabel = UILabel()
    private let chargeBar = ForceMeterView()
    private let forceGuideLabel = UILabel()
    private var trainerEnabled = false
    private var scoreTapCount = 0
    private var lastScoreTap: CFTimeInterval = 0
    private let resultPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
    private var resultTitle: UILabel!
    private var resultSubtitle: UILabel!
    private let resultScore = UILabel()
    private let exitOnlineButton = UIButton(type: .system)
    private let soundButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let hud = PassthroughView()
    private let home = UIView()
    private let homeBest = UILabel()
    private let homeNotice = UILabel() // why an online session ended
    private let standingsTable = PlayerTable(fontSize: 12, valueWidth: 22, noteWidth: 26, columnSpacing: 4)
    private let rankingTable = PlayerTable(fontSize: 14, rankWidth: 20, valueWidth: 34, noteWidth: 30)
    private var standings: [Standing] = []
    private var nameLabels: [Int: UILabel] = [:]
    private var match: OnlineMatch?
    private var lobby: LobbyViewController?
    private var countdownToken = 0
    private var readyCountdownToken = 0
    private var awaitingResult = false // the result is in; waiting for the last fall to play out
    private var bestScore = UserDefaults.standard.integer(forKey: "bestScore")
    private var smokeResult: [String: Any] = [:]
    private var didDisplayFloatingScore = false
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        gameView = ARView(frame: view.bounds, cameraMode: .nonAR, automaticallyConfigureSession: false)
        gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gameView.isUserInteractionEnabled = false
        view.addSubview(gameView)
        game = GameRenderer(view: gameView)
        playInputView.frame = view.bounds
        playInputView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playInputView.backgroundColor = .clear
        playInputView.isMultipleTouchEnabled = false
        playInputView.isAccessibilityElement = true
        playInputView.accessibilityIdentifier = "playArea"
        playInputView.accessibilityLabel = "游戏区域，按住蓄力，松手立即跳跃"
        view.addSubview(playInputView)
        hud.frame = view.bounds
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hud)
        playInputView.began = { [weak self] in self?.game.beginCharge() }
        playInputView.ended = { [weak self] in self?.game.releaseCharge() }
        playInputView.cancelled = { [weak self] in self?.game.cancelTouch() }
        game.onDiagnostics = { [weak self] value in
            guard let self else { return }
            let online = self.match.map { ";desyncs=\($0.desyncs)" } ?? ""
            self.playInputView.accessibilityValue = value + ";popupDisplayed=\(self.didDisplayFloatingScore ? 1 : 0);trainer=\(self.trainerEnabled ? 1 : 0)" + online
        }
        buildHUD()
        game.onScore = { [weak self] score, combo in
            guard let self else { return }
            self.scoreLabel.text = "\(score)"
            self.scoreLabel.accessibilityValue = "\(score)"
            if score > self.bestScore {
                self.bestScore = score
                UserDefaults.standard.set(score, forKey: "bestScore")
            }
            self.bestLabel.text = "BEST  \(self.bestScore)"
        }
        game.onFloatingScore = { [weak self] point, amount, alpha in
            guard let self else { return }
            guard let point else { self.floatingScoreLabel.isHidden = true; return }
            self.floatingScoreLabel.text = "+\(amount)"
            self.floatingScoreLabel.center = point
            self.floatingScoreLabel.alpha = CGFloat(alpha)
            self.floatingScoreLabel.isHidden = false
            if alpha > 0 && self.view.bounds.contains(point) { self.didDisplayFloatingScore = true }
        }
        game.onMessage = { [weak self] in self?.messageLabel.text = $0 }
        game.onCharge = { [weak self] value in
            self?.chargeBar.progress = value
            self?.updateForceCaption()
        }
        game.onForceGuide = { [weak self] guide in
            self?.chargeBar.guide = guide
            self?.updateForceCaption()
        }
        game.onGameOver = { [weak self] score in
            guard let self else { return }
            // Online, the server's result decides when the panel appears.
            if self.match != nil {
                if !self.awaitingResult { self.messageLabel.text = "已掉落 · 观战中" }
                return
            }
            self.resultScore.text = "\(score)"
            self.resultPanel.isHidden = false
            self.messageLabel.text = ""
        }
        game.onRemoteLabels = { [weak self] in self?.showNameLabels($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(willPause), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didResume), name: UIApplication.didBecomeActiveNotification, object: nil)
        let deterministicRun = ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--ui-test")
        game.restart(seed: deterministicRun ? 1337 : nil)
        buildHome()
        showHome(animated: false)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { runSmokeTest() }
        #endif
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor = UIColor(hex: 0x303943)) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = .center
        return label
    }
    private func buildHUD() {
        let title = label("JUMP / JUMP", size: 13, weight: .bold)
        title.accessibilityIdentifier = "gameTitle"
        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 64, weight: .light)
        scoreLabel.textColor = UIColor(hex: 0x303943)
        scoreLabel.textAlignment = .center
        scoreLabel.accessibilityIdentifier = "score"
        scoreLabel.isUserInteractionEnabled = true
        scoreLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapScore)))
        bestLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        bestLabel.textColor = UIColor(hex: 0x7C8588)
        bestLabel.textAlignment = .center
        let heading = UIStackView(arrangedSubviews: [title, scoreLabel, bestLabel])
        heading.axis = .vertical; heading.spacing = 5
        heading.isUserInteractionEnabled = true
        hud.addSubview(heading)
        heading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            heading.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        messageLabel.font = .systemFont(ofSize: 16, weight: .medium)
        messageLabel.textColor = UIColor(hex: 0x48535A)
        messageLabel.textAlignment = .center
        messageLabel.accessibilityIdentifier = "gameMessage"
        messageLabel.isUserInteractionEnabled = false
        hud.addSubview(messageLabel)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        chargeBar.backgroundColor = .clear
        chargeBar.isUserInteractionEnabled = false
        chargeBar.isAccessibilityElement = true
        chargeBar.accessibilityIdentifier = "forceMeter"
        chargeBar.accessibilityLabel = "辅助蓄力条，绿色为安全区间，深色线为中心力度"
        chargeBar.isHidden = true // Revealed only by ten consecutive score taps.
        hud.addSubview(chargeBar)
        chargeBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.bottomAnchor.constraint(equalTo: chargeBar.topAnchor, constant: -20),
            chargeBar.widthAnchor.constraint(equalToConstant: 220),
            chargeBar.heightAnchor.constraint(equalToConstant: 16),
            chargeBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chargeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -75)
        ])
        forceGuideLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        forceGuideLabel.textColor = UIColor(hex: 0x365B4D)
        forceGuideLabel.textAlignment = .center
        forceGuideLabel.adjustsFontSizeToFitWidth = true
        forceGuideLabel.isUserInteractionEnabled = false
        forceGuideLabel.isHidden = true
        forceGuideLabel.accessibilityIdentifier = "forceGuideText"
        hud.addSubview(forceGuideLabel)
        forceGuideLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            forceGuideLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            forceGuideLabel.widthAnchor.constraint(equalToConstant: 290),
            forceGuideLabel.bottomAnchor.constraint(equalTo: chargeBar.topAnchor, constant: -8)
        ])
        configureButton(soundButton, title: "声音 开", action: #selector(toggleSound))
        soundButton.accessibilityIdentifier = "sound"
        configureButton(resetButton, title: "重开", action: #selector(restart))
        resetButton.accessibilityIdentifier = "restart"
        configureButton(homeButton, title: "首页", action: #selector(goHome))
        homeButton.accessibilityIdentifier = "home"
        standingsTable.isUserInteractionEnabled = false
        standingsTable.accessibilityIdentifier = "standings"
        hud.addSubview(standingsTable)
        standingsTable.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            standingsTable.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            standingsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            // Stops short of the centered score heading.
            standingsTable.widthAnchor.constraint(equalToConstant: 124)
        ])
        let controls = UIStackView(arrangedSubviews: [soundButton, resetButton, homeButton])
        controls.spacing = 12
        hud.addSubview(controls); controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controls.topAnchor.constraint(equalTo: chargeBar.bottomAnchor, constant: 16)
        ])
        floatingScoreLabel.font = .monospacedDigitSystemFont(ofSize: 29, weight: .bold)
        floatingScoreLabel.textColor = UIColor(hex: 0x365B4D)
        floatingScoreLabel.textAlignment = .center
        floatingScoreLabel.bounds = CGRect(x: 0, y: 0, width: 140, height: 50)
        floatingScoreLabel.isUserInteractionEnabled = false
        floatingScoreLabel.isHidden = true
        floatingScoreLabel.accessibilityIdentifier = "floatingScore"
        hud.addSubview(floatingScoreLabel)
        buildResultPanel()
    }
    @objc private func tapScore() {
        guard match == nil else { return } // no assist in online races
        let now = CACurrentMediaTime()
        if now - lastScoreTap > 3 { scoreTapCount = 0 }
        lastScoreTap = now
        scoreTapCount += 1
        guard scoreTapCount == 10 else { return }
        scoreTapCount = 0
        trainerEnabled.toggle()
        chargeBar.isHidden = !trainerEnabled
        forceGuideLabel.isHidden = !trainerEnabled
        messageLabel.isHidden = trainerEnabled
        updateForceCaption()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func updateForceCaption() {
        guard trainerEnabled, let guide = chargeBar.guide else { return }
        let percent = guide.idealSeconds / ForceGuide.fullChargeDuration * 100
        let caption = String(format: "辅助 · 目标 %.0f%%（%.2f 秒） · 当前 %.0f%%", percent, guide.idealSeconds, chargeBar.progress * 100)
        if forceGuideLabel.text != caption { forceGuideLabel.text = caption }
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseForegroundColor = UIColor(hex: 0x365B4D)
        config.baseBackgroundColor = UIColor(hex: 0x73B6A0)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private func buildResultPanel() {
        resultPanel.layer.cornerRadius = 28
        resultPanel.clipsToBounds = true
        resultPanel.isHidden = true
        resultPanel.accessibilityIdentifier = "gameOver"
        hud.addSubview(resultPanel)
        resultPanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resultPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resultPanel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            resultPanel.widthAnchor.constraint(equalToConstant: 270)
        ])
        resultTitle = label("这一跳，告一段落", size: 19, weight: .semibold)
        resultScore.font = .monospacedDigitSystemFont(ofSize: 70, weight: .light)
        resultScore.textAlignment = .center
        resultScore.textColor = UIColor(hex: 0x303943)
        resultSubtitle = label("调整按压时间，再试一次", size: 13, weight: .regular, color: .secondaryLabel)
        resultSubtitle.numberOfLines = 0
        resultSubtitle.accessibilityIdentifier = "resultNote"
        rankingTable.accessibilityIdentifier = "resultDetail"
        rankingTable.isHidden = true
        let button = UIButton(type: .system)
        configureButton(button, title: "再来一局", action: #selector(restart))
        button.accessibilityIdentifier = "playAgain"
        configureButton(exitOnlineButton, title: "退出联机", action: #selector(goHome))
        exitOnlineButton.accessibilityIdentifier = "exitOnline"
        exitOnlineButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [resultTitle, resultScore, rankingTable, resultSubtitle, button, exitOnlineButton])
        stack.axis = .vertical; stack.spacing = 17
        resultPanel.contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: resultPanel.contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: resultPanel.contentView.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: resultPanel.contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: resultPanel.contentView.trailingAnchor, constant: -22)
        ])
    }
    @objc private func restart() {
        if let match { // "再来一局" after an online result
            guard match.players.count > 1 else { exitOnline(notice: "其他玩家都已离开房间"); return }
            stopReadyCountdown()
            resultPanel.isHidden = true
            // Back to the room view to wait for everyone else. Ready up only once
            // it is on screen: an instant start dismisses it, which UIKit
            // refuses mid-presentation.
            presentLobby(for: match) { match.ready() }.showLobby(match.players, selfID: match.playerID)
            return
        }
        scoreTapCount = 0; lastScoreTap = 0
        playInputView.cancelActiveTouch()
        resultPanel.isHidden = true
        didDisplayFloatingScore = false
        game.restart(seed: ProcessInfo.processInfo.arguments.contains("--ui-test") ? 1337 : nil)
    }
    @objc private func toggleSound() {
        game.assets.soundEnabled.toggle()
        if !game.assets.soundEnabled { game.assets.stopAll() }
        soundButton.configuration?.title = game.assets.soundEnabled ? "声音 开" : "声音 关"
    }
    // MARK: Home

    // The live scene is the backdrop: the piece waits on its first platform
    // while the player picks a mode.
    private func buildHome() {
        home.frame = view.bounds
        home.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(home)
        let mark = label("JUMP / JUMP", size: 13, weight: .bold)
        let title = label("跳一跳", size: 56, weight: .light)
        let hint = label("按住蓄力，松手起跳", size: 15, weight: .regular, color: UIColor(hex: 0x7C8588))
        let heading = UIStackView(arrangedSubviews: [mark, title, hint])
        heading.axis = .vertical
        heading.spacing = 4
        heading.setCustomSpacing(10, after: title)
        let solo = UIButton(type: .system)
        configureHomeButton(solo, title: "单人游戏", subtitle: nil, filled: true, action: #selector(startSolo))
        solo.accessibilityIdentifier = "playSolo"
        let online = UIButton(type: .system)
        configureHomeButton(online, title: "局域网联机", subtitle: "和同一 Wi-Fi 下的朋友同场比赛", filled: false, action: #selector(openLobby))
        online.accessibilityIdentifier = "playOnline"
        homeBest.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        homeBest.textColor = UIColor(hex: 0x7C8588)
        homeBest.textAlignment = .center
        homeBest.accessibilityIdentifier = "homeBest"
        homeNotice.font = .systemFont(ofSize: 14, weight: .medium)
        homeNotice.textColor = UIColor(hex: 0x48535A)
        homeNotice.textAlignment = .center
        homeNotice.numberOfLines = 0
        homeNotice.accessibilityIdentifier = "homeNotice"
        let choices = UIStackView(arrangedSubviews: [homeNotice, solo, online, homeBest])
        choices.axis = .vertical
        choices.spacing = 12
        choices.setCustomSpacing(20, after: online)
        home.addSubview(heading)
        home.addSubview(choices)
        heading.translatesAutoresizingMaskIntoConstraints = false
        choices.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            heading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            choices.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            choices.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            choices.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28)
        ])
    }

    private func configureHomeButton(_ button: UIButton, title: String, subtitle: String?, filled: Bool, action: Selector) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.subtitle = subtitle
        config.titleAlignment = .center
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }
        config.baseBackgroundColor = UIColor(hex: 0x73B6A0)
        config.baseForegroundColor = filled ? .white : UIColor(hex: 0x365B4D)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // An empty notice collapses to nothing, so no stack view hiding is needed.
    private func showHome(animated: Bool = true, notice: String? = nil) {
        playInputView.cancelActiveTouch()
        homeNotice.text = notice
        homeBest.text = bestScore > 0 ? "最高纪录 \(bestScore)" : nil
        setHomeVisible(true, animated: animated)
    }

    private func setHomeVisible(_ visible: Bool, animated: Bool = true) {
        // The play area only takes touches (and appears to UI tests) in a game.
        playInputView.isHidden = visible
        home.isHidden = false
        hud.isHidden = false
        let apply = {
            self.home.alpha = visible ? 1 : 0
            self.hud.alpha = visible ? 0 : 1
        }
        let finish = {
            self.home.isHidden = !visible
            self.hud.isHidden = visible
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { apply(); finish(); return }
        UIView.animate(withDuration: 0.25, animations: apply) { _ in finish() }
    }

    // Every way back to the menu restarts first, so the scene behind it is
    // already a fresh run.
    @objc private func startSolo() {
        homeNotice.text = nil
        setHomeVisible(false)
    }

    // The bottom-right button: back to the menu, or out of an online race.
    @objc private func goHome() {
        if match != nil { exitOnline(); return }
        restart()
        showHome()
    }

    // MARK: Online racing

    private static let outStatus = ["fell": "掉落", "idle": "挂机", "disconnected": "断线", "left": "离开"]

    @objc private func openLobby() {
        guard match == nil else { return }
        homeNotice.text = nil
        playInputView.cancelActiveTouch()
        // No assist online: switch it off, and keep its numbers out of the
        // play area's accessibility value (VoiceOver would read them aloud).
        if trainerEnabled {
            trainerEnabled = false
            chargeBar.isHidden = true; forceGuideLabel.isHidden = true; messageLabel.isHidden = false
        }
        game.revealsIdealPress = ProcessInfo.processInfo.arguments.contains("--ui-test")
        let match = OnlineMatch(game: game)
        match.onRooms = { [weak self] in self?.lobby?.showRooms($0) }
        match.onRemoved = { [weak self] in self?.removedFromRoom($0) }
        match.onLobby = { [weak self] in self?.showLobby($0) }
        match.onStart = { [weak self] in self?.startRace(countdown: $0) }
        match.onStandings = { [weak self] in self?.showStandings($0) }
        match.onNotice = { [weak self] in self?.showNotice($0) }
        match.onReadyWarning = { [weak self] in self?.startReadyCountdown($0) }
        match.onResult = { [weak self] in self?.showResult($0) }
        match.onClosed = { [weak self] in self?.connectionClosed($0) }
        self.match = match
        homeButton.configuration?.title = "退出联机"
        // Disable rather than hide: hiding a sibling while this title changes
        // collapses every button in the stack to zero width (UIKit).
        resetButton.isEnabled = false
        presentLobby(for: match)
    }

    @discardableResult
    private func presentLobby(for match: OnlineMatch, presented: (() -> Void)? = nil) -> LobbyViewController {
        let lobby = LobbyViewController()
        lobby.onConnect = { [weak match] in match?.connect(to: $0) }
        lobby.onCreate = { [weak match] name, password in match?.create(name: name, password: password) }
        lobby.onJoin = { [weak match] room, name, password in match?.join(room: room, name: name, password: password) }
        lobby.onReady = { [weak self, weak match] in
            match?.ready()
            self?.stopReadyCountdown()
        }
        lobby.onLeave = { [weak self, weak match] in
            match?.leaveRoom()
            self?.stopReadyCountdown()
        }
        lobby.onSwitchServer = { [weak match] in match?.disconnect() }
        lobby.onClose = { [weak self] in self?.exitOnline() }
        lobby.presentationController?.delegate = self
        lobby.loadViewIfNeeded()
        self.lobby = lobby
        present(lobby, animated: true, completion: presented)
        return lobby
    }

    private func exitOnline(notice: String? = nil) {
        countdownToken += 1
        readyCountdownToken += 1
        awaitingResult = false
        match?.leave(); match = nil
        lobby?.dismiss(animated: true); lobby = nil
        game.isOnline = false; game.isInputLocked = false; game.revealsIdealPress = true
        standings = []
        standingsTable.show([])
        game.setSelfColor(nil)
        homeButton.configuration?.title = "首页"
        resetButton.isEnabled = true
        exitOnlineButton.isHidden = true
        resultTitle.text = "这一跳，告一段落"
        resultSubtitle.text = "调整按压时间，再试一次"
        resultSubtitle.textColor = .secondaryLabel
        resultSubtitle.isHidden = false
        rankingTable.isHidden = true
        restart()
        showHome(notice: notice)
    }

    private func showLobby(_ players: [LobbyPlayer]) {
        // Waiting alone before the first race is normal; after a race it means
        // everyone else left, so there is nobody to rematch.
        if let match, match.hasRaced, !match.isRacing, players.count <= 1, lobby != nil {
            exitOnline(notice: "其他玩家都已离开房间")
            return
        }
        if players.first(where: { $0.playerID == match?.playerID })?.ready == true { stopReadyCountdown() }
        lobby?.showLobby(players, selfID: match?.playerID)
    }

    private func startRace(countdown: TimeInterval) {
        stopReadyCountdown()
        lobby?.dismiss(animated: true); lobby = nil
        setHomeVisible(false)
        resultPanel.isHidden = true
        exitOnlineButton.isHidden = true
        playInputView.cancelActiveTouch()
        countdownToken += 1
        let token = countdownToken
        let seconds = Int(countdown.rounded(.up))
        for step in 0...seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + countdown - TimeInterval(seconds - step)) { [weak self] in
                guard let self, self.countdownToken == token else { return }
                self.messageLabel.text = step == seconds ? "开跑！" : "\(seconds - step)"
            }
        }
    }

    private func showStandings(_ standings: [Standing]) {
        self.standings = standings
        standingsTable.show(standings.map { standing in
            PlayerTable.Row(color: Figure.color(standing.color), name: standing.name, isSelf: standing.isSelf,
                            value: "\(standing.score)", note: standing.status.map { Self.outStatus[$0] ?? $0 },
                            dimmed: standing.status != nil)
        })
    }

    // The server warns `seconds` before removing a player who has not readied;
    // count down wherever they are looking: the room view or the result panel.
    private func startReadyCountdown(_ seconds: Int) {
        readyCountdownToken += 1
        let token = readyCountdownToken
        for step in 0..<max(seconds, 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step)) { [weak self] in
                guard let self, self.readyCountdownToken == token else { return }
                self.showReadyCountdown(seconds - step)
            }
        }
    }

    private func stopReadyCountdown() {
        readyCountdownToken += 1
        showReadyCountdown(nil)
    }

    private func showReadyCountdown(_ seconds: Int?) {
        if let lobby { lobby.showReadyCountdown(seconds); return }
        guard match != nil, !resultPanel.isHidden else { return }
        resultSubtitle.text = seconds.map { "\($0) 秒内不点「再来一局」将退出房间" }
        resultSubtitle.textColor = UIColor(hex: 0xC4502F)
        resultSubtitle.isHidden = seconds == nil
    }

    private func showNotice(_ text: String) {
        if let lobby { lobby.showStatus(text) } else { messageLabel.text = text }
    }

    private func showResult(_ ranking: [RankEntry]) {
        awaitingResult = true
        game.afterRacersSettle { [weak self] in
            self?.awaitingResult = false
            self?.presentResult(ranking)
        }
    }

    private func presentResult(_ ranking: [RankEntry]) {
        let selfID = match?.playerID
        resultTitle.text = "本局第 \((ranking.firstIndex { $0.playerID == selfID } ?? 0) + 1) 名"
        resultScore.text = "\(ranking.first { $0.playerID == selfID }?.score ?? 0)"
        rankingTable.show(ranking.enumerated().map { place, entry in
            let color = standings.first { $0.playerID == entry.playerID }?.color ?? place
            // Falling is how every race ends; only forfeits get a note.
            return PlayerTable.Row(rank: place + 1, color: Figure.color(color), name: entry.name, isSelf: entry.playerID == selfID,
                                   value: "\(entry.score)", note: entry.status == "fell" ? nil : Self.outStatus[entry.status] ?? entry.status)
        })
        resultSubtitle.isHidden = true
        rankingTable.isHidden = false
        exitOnlineButton.isHidden = false
        resultPanel.isHidden = false
        messageLabel.text = ""
    }

    // Removed for not readying in time. The connection stays: from the room
    // view that means back to the room list, from the result panel back home.
    private func removedFromRoom(_ reason: String) {
        readyCountdownToken += 1
        if let lobby { lobby.showRemoved(reason); return }
        exitOnline(notice: reason)
    }

    private func connectionClosed(_ reason: String) {
        readyCountdownToken += 1
        if let lobby, match?.hasRaced != true { lobby.showDisconnected(reason); return }
        exitOnline(notice: reason)
    }

    private func showNameLabels(_ labels: [RemoteLabel]) {
        let ids = Set(labels.map(\.id))
        for (id, label) in nameLabels where !ids.contains(id) {
            label.removeFromSuperview()
            nameLabels[id] = nil
        }
        for item in labels {
            let label = nameLabels[item.id] ?? makeNameLabel(item.name, color: item.color)
            nameLabels[item.id] = label
            if let point = item.point, view.bounds.contains(point) {
                label.center = point
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
    }

    private func makeNameLabel(_ name: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = name
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = color
        label.sizeToFit()
        label.isUserInteractionEnabled = false
        view.insertSubview(label, aboveSubview: playInputView)
        return label
    }

    @objc private func willPause() { playInputView.cancelActiveTouch(); game.cancelTouch(); game.isPaused = true; game.assets.stopAll() }
    @objc private func didResume() { game.isPaused = false }
    deinit { NotificationCenter.default.removeObserver(self) }

    #if DEBUG
    // Deterministic simulation smoke test: uses the same trajectory/update/landing
    // path as touch input, but does not claim to test real touch delivery or visuals.
    private func runSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.game.debugJumpToCenter() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            self.smokeResult["successfulLanding"] = self.game.debugScore > 0 && self.game.phase == .ready
            self.game.debugJump(press: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.smokeResult["stayedOnCurrentPlatform"] = self.game.phase == .ready
            self.game.debugJump(press: 3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self else { return }
            self.smokeResult["failureShowsResultPanel"] = self.game.phase == .gameOver && !self.resultPanel.isHidden
            self.restart()
            self.smokeResult["restartResetsScore"] = self.game.debugScore == 0 && self.game.phase == .ready
            self.smokeResult["framework"] = "UIKit + RealityKit nonAR"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke-result.json")
            if let data = try? JSONSerialization.data(withJSONObject: self.smokeResult, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
            print("JUMPJUMP_SMOKE_RESULT \(self.smokeResult)")
        }
    }
    #endif
}

extension GameViewController: UIAdaptivePresentationControllerDelegate {
    // Swiping the lobby away before joining returns to single player.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        exitOnline()
    }
}
