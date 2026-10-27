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
    private let resultScore = UILabel()
    private let soundButton = UIButton(type: .system)
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
        playInputView.began = { [weak self] in self?.game.beginCharge() }
        playInputView.ended = { [weak self] in self?.game.releaseCharge() }
        playInputView.cancelled = { [weak self] in self?.game.cancelTouch() }
        game.onDiagnostics = { [weak self] value in
            guard let self else { return }
            self.playInputView.accessibilityValue = value + ";popupDisplayed=\(self.didDisplayFloatingScore ? 1 : 0);trainer=\(self.trainerEnabled ? 1 : 0)"
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
            self?.resultScore.text = "\(score)"
            self?.resultPanel.isHidden = false
            self?.messageLabel.text = ""
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willPause), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didResume), name: UIApplication.didBecomeActiveNotification, object: nil)
        let deterministicRun = ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--ui-test")
        game.restart(seed: deterministicRun ? 1337 : nil)
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
        view.addSubview(heading)
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
        view.addSubview(messageLabel)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        chargeBar.backgroundColor = .clear
        chargeBar.isUserInteractionEnabled = false
        chargeBar.isAccessibilityElement = true
        chargeBar.accessibilityIdentifier = "forceMeter"
        chargeBar.accessibilityLabel = "辅助蓄力条，绿色为安全区间，深色线为中心力度"
        chargeBar.isHidden = true // Revealed only by ten consecutive score taps.
        view.addSubview(chargeBar)
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
        view.addSubview(forceGuideLabel)
        forceGuideLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            forceGuideLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            forceGuideLabel.widthAnchor.constraint(equalToConstant: 290),
            forceGuideLabel.bottomAnchor.constraint(equalTo: chargeBar.topAnchor, constant: -8)
        ])
        configureButton(soundButton, title: "声音 开", action: #selector(toggleSound))
        soundButton.accessibilityIdentifier = "sound"
        let reset = UIButton(type: .system)
        configureButton(reset, title: "重开", action: #selector(restart))
        reset.accessibilityIdentifier = "restart"
        let controls = UIStackView(arrangedSubviews: [soundButton, reset])
        controls.spacing = 12
        view.addSubview(controls); controls.translatesAutoresizingMaskIntoConstraints = false
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
        view.addSubview(floatingScoreLabel)
        buildResultPanel()
    }
    @objc private func tapScore() {
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
        view.addSubview(resultPanel)
        resultPanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resultPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resultPanel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            resultPanel.widthAnchor.constraint(equalToConstant: 270)
        ])
        let title = label("这一跳，告一段落", size: 19, weight: .semibold)
        resultScore.font = .monospacedDigitSystemFont(ofSize: 70, weight: .light)
        resultScore.textAlignment = .center
        resultScore.textColor = UIColor(hex: 0x303943)
        let subtitle = label("调整按压时间，再试一次", size: 13, weight: .regular, color: .secondaryLabel)
        let button = UIButton(type: .system)
        configureButton(button, title: "再来一局", action: #selector(restart))
        button.accessibilityIdentifier = "playAgain"
        let stack = UIStackView(arrangedSubviews: [title, resultScore, subtitle, button])
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
