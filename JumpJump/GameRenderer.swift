import UIKit
import RealityKit
import Combine
import simd

final class GameRenderer {
    enum Phase { case ready, charging, jumping, settling, falling, gameOver }
    private(set) var phase: Phase = .ready
    private let view: ARView
    let assets = AssetLibrary()
    private let world = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let character = Entity()
    private let visual = Entity()
    private let shadow = ModelEntity()
    private var updateSubscription: Cancellable?
    private var generator = PlatformGenerator(seed: 1)
    private var platforms: [(PlatformSpec, Entity)] = []
    private var currentIndex = 0
    private var trajectory: JumpTrajectory?
    private var elapsed: Float = 0
    private var chargeStarted: CFTimeInterval = 0
    private var cameraTarget = SIMD3<Float>.zero
    private var desiredCameraTarget = SIMD3<Float>.zero
    private var score = 0
    private var combo = 0
    private var runSeed = 1
    private var ring: ModelEntity?
    private var ringAge: Float = 0
    private var hasPlayedChargeLoop = false
    private var jumpCount = 0
    private var lastPress: Float = 0
    private var maximumJumpHeight: Float = 0
    private var currentCharge: Float = 0
    private struct ArrivingPlatform { let entity: Entity; var elapsed: Float = 0 }
    private var arrivingPlatforms: [ArrivingPlatform] = []
    private var arrivalsStarted: Set<Int> = []
    private var nextMinScale: Float = 1
    private var idealPress: Float = 0
    private struct FloatingScore { let amount: Int; let position: SIMD3<Float>; var age: Float = 0 }
    private var floatingScore: FloatingScore?
    private var scorePops = 0
    var onForceGuide: ((ForceGuide) -> Void)?
    var onFloatingScore: ((CGPoint?, Int, Float) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var onScore: ((Int, Int) -> Void)?
    var onMessage: ((String) -> Void)?
    var onGameOver: ((Int) -> Void)?
    var onCharge: ((Float) -> Void)?
    var isPaused = false

    init(view: ARView) {
        self.view = view
        view.environment.background = .color(UIColor(hex: 0xE8E5DF))
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        camera.camera.fieldOfViewInDegrees = 20
        world.addChild(camera)
        let light = DirectionalLight()
        light.light.color = .white
        light.light.intensity = 2400
        light.look(at: .zero, from: SIMD3(-3, 8, 4), relativeTo: nil)
        world.addChild(light)
        buildCharacter()
        world.addChild(character)
        var shadowMaterial = UnlitMaterial(color: UIColor.black)
        shadowMaterial.blending = .transparent(opacity: 0.16)
        shadow.model = ModelComponent(mesh: .generateSphere(radius: 0.15), materials: [shadowMaterial])
        shadow.scale = SIMD3(1, 0.01, 0.65)
        world.addChild(shadow)
        view.scene.addAnchor(world)
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(delta: Float(event.deltaTime))
        }
    }

    private func buildCharacter() {
        character.addChild(visual)
        let body = ModelEntity(mesh: .generateCylinder(height: 0.31, radius: 0.105),
                               materials: [SimpleMaterial(color: UIColor(hex: 0x343946), roughness: 0.8, isMetallic: false)])
        body.position.y = 0.155
        visual.addChild(body)
        let neck = ModelEntity(mesh: .generateCylinder(height: 0.07, radius: 0.055),
                               materials: [SimpleMaterial(color: UIColor(hex: 0x343946), roughness: 0.8, isMetallic: false)])
        neck.position.y = 0.34
        visual.addChild(neck)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.095),
                               materials: [SimpleMaterial(color: UIColor(hex: 0xE3B787), roughness: 0.65, isMetallic: false)])
        head.position.y = 0.445
        visual.addChild(head)
        let cap = ModelEntity(mesh: .generateCylinder(height: 0.06, radius: 0.092),
                              materials: [SimpleMaterial(color: UIColor(hex: 0x303440), roughness: 0.8, isMetallic: false)])
        cap.position.y = 0.51
        visual.addChild(cap)
    }

    func restart(seed: Int? = nil) {
        assets.stopAll()
        platforms.forEach { $0.1.removeFromParent() }
        platforms.removeAll()
        arrivingPlatforms.removeAll(); arrivalsStarted.removeAll()
        floatingScore = nil; scorePops = 0; nextMinScale = 1
        onFloatingScore?(nil, 0, 0)
        ring?.removeFromParent(); ring = nil
        runSeed = seed ?? Int.random(in: 1..<233280)
        generator = PlatformGenerator(seed: runSeed)
        let first = PlatformSpec(id: 0, center: .zero, radius: 0.5, style: .mint)
        let next = generator.next(after: first, score: 0)
        platforms = [(first, makePlatform(first)), (next, makePlatform(next))]
        platforms.forEach { world.addChild($0.1) }
        currentIndex = 0
        score = 0; combo = 0; elapsed = 0; trajectory = nil
        jumpCount = 0; lastPress = 0; maximumJumpHeight = 0; currentCharge = 0
        hasPlayedChargeLoop = false
        character.position = .zero
        visual.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        visual.scale = .one
        desiredCameraTarget = midpoint(first, next)
        cameraTarget = desiredCameraTarget
        updateCamera()
        startArrival(for: next, entity: platforms[1].1)
        updateIdealPress()
        phase = .ready
        onScore?(score, combo); onCharge?(0)
        onMessage?("")
        publishDiagnostics()
        assets.play("start")
    }

    private func makePlatform(_ spec: PlatformSpec) -> Entity {
        let root = Entity()
        root.position = SIMD3(spec.center.x, 0, spec.center.y)
        let color: UIColor
        switch spec.style {
        case .mint: color = UIColor(hex: 0x73B6A0)
        case .charcoal: color = UIColor(hex: 0x494D59)
        case .tiled: color = UIColor(hex: 0xC8C9C4)
        case .parcel: color = UIColor(hex: 0xD9B584)
        case .cylinder: color = UIColor(hex: 0xE3D3BA)
        }
        let mesh: MeshResource = spec.style.isRound ? .generateCylinder(height: 0.55, radius: spec.radius) : .generateBox(size: SIMD3(spec.radius * 2, 0.55, spec.radius * 2), cornerRadius: 0.012)
        let body = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 0.9, isMetallic: false)])
        body.position.y = -0.275
        root.addChild(body)
        let textureName: String?
        switch spec.style {
        case .tiled: textureName = "gray"
        case .parcel: textureName = "box_top"
        default: textureName = nil
        }
        if let textureName {
            let top = ModelEntity(mesh: .generatePlane(width: spec.radius * 1.99, depth: spec.radius * 1.99),
                                  materials: [assets.topMaterial(textureName, fallback: color)])
            top.position.y = 0.003
            root.addChild(top)
        }
        // A thin center marker makes the perfect-landing target legible.
        var markerMaterial = UnlitMaterial(color: UIColor.white)
        markerMaterial.blending = .transparent(opacity: 0.24)
        let marker = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.045), materials: [markerMaterial])
        marker.position.y = 0.006
        root.addChild(marker)
        return root
    }

    func beginCharge() {
        guard phase == .ready, !isPaused else { return }
        phase = .charging
        chargeStarted = CACurrentMediaTime()
        hasPlayedChargeLoop = false
        currentCharge = 0
        onMessage?("")
        publishDiagnostics()
        assets.play("scale_intro")
        UIImpactFeedbackGenerator(style: .soft).prepare()
    }
    func releaseCharge() {
        // No minimum duration and no progress threshold: every valid release jumps.
        guard phase == .charging, !isPaused else { return }
        let press = max(0, Float(CACurrentMediaTime() - chargeStarted))
        lastPress = press
        jumpCount += 1
        maximumJumpHeight = 0
        currentCharge = 0
        assets.stop("scale_intro"); assets.stop("scale_loop")
        let next = platforms[currentIndex + 1].0
        trajectory = JumpTrajectory(start: character.position, target: next.center, pressSeconds: press)
        elapsed = 0
        visual.scale = .one
        platforms[currentIndex].1.scale = .one
        phase = .jumping
        onCharge?(0)
        onMessage?("")
        publishDiagnostics()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func cancelTouch() {
        currentCharge = 0
        if phase == .charging {
            phase = .ready
            visual.scale = .one
            platforms[currentIndex].1.scale = .one
            assets.stop("scale_intro"); assets.stop("scale_loop")
            onCharge?(0)
        }
    }

    private func update(delta: Float) {
        guard !isPaused else { return }
        let dt = min(delta, 1.0 / 15)
        cameraTarget += (desiredCameraTarget - cameraTarget) * (1 - exp(-dt * 5))
        updateCamera()
        updateArrivals(delta: dt)
        updateFloatingScore(delta: dt)
        if let ring {
            ringAge += dt
            let size = 1 + ringAge * 3
            ring.scale = SIMD3(size, 1, size)
            if ringAge > 0.55 { ring.removeFromParent(); self.ring = nil }
        }
        switch phase {
        case .charging:
            let t = Float(CACurrentMediaTime() - chargeStarted)
            let compression = min(t / 1.5, 1) * 0.35
            visual.scale = SIMD3(1 + compression * 0.2, 1 - compression, 1 + compression * 0.2)
            platforms[currentIndex].1.scale.y = 1 - compression * 0.12
            currentCharge = min(t / 1.5, 1)
            onCharge?(currentCharge)
            // Sound state must not reuse the flight animation clock.
            if t > 0.35 && !hasPlayedChargeLoop {
                assets.stop("scale_intro")
                assets.play("scale_loop", loop: true)
                hasPlayedChargeLoop = true
            }
        case .jumping:
            guard let trajectory else { return }
            elapsed += dt
            let t = min(elapsed, trajectory.duration)
            character.position = trajectory.position(at: t)
            maximumJumpHeight = max(maximumJumpHeight, character.position.y)
            let progress = t / trajectory.duration
            let axis = SIMD3(trajectory.direction.y, 0, -trajectory.direction.x)
            visual.orientation = simd_quatf(angle: progress * .pi * 2, axis: axis)
            if elapsed >= trajectory.duration { resolveLanding(trajectory) }
        case .settling:
            elapsed += dt
            let squash = sin(min(elapsed / 0.18, 1) * .pi) * 0.18
            visual.scale = SIMD3(1 + squash * 0.2, 1 - squash, 1 + squash * 0.2)
            // Landing recovery belongs only to the character. Existing platforms
            // must never replay their appearance animation after a short/stayed jump.
            if elapsed >= 0.2 { visual.scale = .one; phase = .ready }
        case .falling:
            elapsed += dt
            character.position.y -= (1 + elapsed * 10) * dt
            visual.orientation = simd_quatf(angle: min(elapsed * 4, 1.7), axis: SIMD3(1, 0, 0.5))
            if elapsed > 0.65 { phase = .gameOver; onGameOver?(score) }
        case .ready, .gameOver: break
        }
        shadow.position = SIMD3(character.position.x, 0.009, character.position.z)
        let onPlatform = platforms.contains { $0.0.contains(SIMD2(character.position.x, character.position.z)) }
        shadow.isEnabled = onPlatform && phase != .falling && phase != .gameOver
        let shrinking = max(0.45, 1 - max(character.position.y, 0) * 0.3)
        shadow.scale = SIMD3(shrinking, 0.01, shrinking * 0.65)
        // Recompute from the actual standing position, including short-hop drift.
        // In-flight input is disabled; its next hint is refreshed on landing.
        if phase == .ready || phase == .charging { updateIdealPress() }
        publishDiagnostics()
    }

    private func startArrival(for spec: PlatformSpec, entity: Entity) {
        // Per-platform ownership: reused/stayed targets cannot acquire a second task.
        guard arrivalsStarted.insert(spec.id).inserted else { return }
        entity.scale = .one
        entity.position.y = PlatformArrivalAnimation.startHeight
        arrivingPlatforms.append(ArrivingPlatform(entity: entity))
    }

    private func updateArrivals(delta: Float) {
        for index in arrivingPlatforms.indices.reversed() {
            arrivingPlatforms[index].elapsed += delta
            let arrival = arrivingPlatforms[index]
            guard arrival.entity.parent != nil else { arrivingPlatforms.remove(at: index); continue }
            arrival.entity.position.y = PlatformArrivalAnimation.height(at: arrival.elapsed)
            if arrival.elapsed >= PlatformArrivalAnimation.duration {
                arrival.entity.position.y = 0
                arrivingPlatforms.remove(at: index)
            }
        }
    }

    private func updateFloatingScore(delta: Float) {
        guard var popup = floatingScore else { return }
        popup.age += delta
        let duration: Float = 0.9
        guard popup.age < duration else {
            floatingScore = nil
            onFloatingScore?(nil, 0, 0)
            return
        }
        floatingScore = popup
        let progress = popup.age / duration
        // Reproject the fixed world landing point as the camera follows the route.
        let point = view.project(popup.position).map { CGPoint(x: $0.x, y: $0.y - CGFloat(progress) * 36) }
        let alpha: Float = popup.age < 0.35 ? 1 : (duration - popup.age) / (duration - 0.35)
        onFloatingScore?(point, popup.amount, alpha)
    }

    private func updateIdealPress() {
        let guide = ForceGuide(start: character.position, target: platforms[currentIndex + 1].0)
        idealPress = guide.idealSeconds
        onForceGuide?(guide)
    }

    private func publishDiagnostics() {
        let next = platforms[currentIndex + 1]
        let scale = min(next.1.scale.x, min(next.1.scale.y, next.1.scale.z))
        nextMinScale = min(nextMinScale, scale)
        let base = String(format: "phase=%@;jumps=%d;lastPress=%.3f;maxHeight=%.3f;charge=%.3f", String(describing: phase), jumpCount, lastPress, maximumJumpHeight, currentCharge)
        let animation = String(format: ";nextID=%d;arrivals=%d;nextY=%.3f;nextScale=%.3f;nextMinScale=%.3f;idealPress=%.5f;scorePops=%d;popupVisible=%d", next.0.id, arrivalsStarted.count, next.1.position.y, scale, nextMinScale, idealPress, scorePops, floatingScore == nil ? 0 : 1)
        onDiagnostics?(base + animation)
    }

    private func resolveLanding(_ trajectory: JumpTrajectory) {
        visual.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        character.position.y = 0
        let result = trajectory.hit(current: platforms[currentIndex].0, next: platforms[currentIndex + 1].0)
        switch result {
        case .perfect, .success:
            let perfect = result == .perfect
            if perfect { combo += 1; score += combo * 2 } else { combo = 0; score += 1 }
            currentIndex += 1
            let next = generator.next(after: platforms[currentIndex].0, score: score)
            let entity = makePlatform(next)
            world.addChild(entity); platforms.append((next, entity))
            nextMinScale = 1
            startArrival(for: next, entity: entity)
            updateIdealPress()
            desiredCameraTarget = midpoint(platforms[currentIndex].0, next)
            if perfect { showRing(at: character.position); assets.play("combo\(min(combo, 8))") }
            else { assets.play("success") }
            onScore?(score, combo)
            floatingScore = FloatingScore(amount: perfect ? combo * 2 : 1, position: character.position + SIMD3(0, 0.58, 0))
            scorePops += 1
            updateFloatingScore(delta: 0)
            onMessage?("")
            UIImpactFeedbackGenerator(style: perfect ? .medium : .light).impactOccurred()
            if currentIndex > 4 { platforms.removeFirst().1.removeFromParent(); currentIndex -= 1 }
            elapsed = 0; phase = .settling
        case .stayed:
            updateIdealPress()
            onMessage?("再多蓄一点力")
            elapsed = 0; phase = .settling
        case .miss:
            combo = 0
            elapsed = 0; phase = .falling
            assets.play("fall")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func showRing(at position: SIMD3<Float>) {
        ring?.removeFromParent()
        var material = UnlitMaterial(color: UIColor(hex: 0xF6C66D))
        material.blending = .transparent(opacity: 0.3)
        let entity = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: 0.11), materials: [material])
        entity.position = position + SIMD3(0, 0.015, 0)
        world.addChild(entity); ring = entity; ringAge = 0
    }
    private func midpoint(_ a: PlatformSpec, _ b: PlatformSpec) -> SIMD3<Float> {
        let middle = (a.center + b.center) * 0.5
        return SIMD3(middle.x, 0.1, middle.y)
    }
    private func updateCamera() {
        camera.look(at: cameraTarget, from: cameraTarget + SIMD3(-16, 16, 16), relativeTo: nil)
    }
    var seed: Int { runSeed }
    #if DEBUG
    var debugScore: Int { score }
    func debugJump(press: Float) {
        guard phase == .ready else { return }
        trajectory = JumpTrajectory(start: character.position, target: platforms[currentIndex + 1].0.center, pressSeconds: press)
        visual.scale = .one
        elapsed = 0
        phase = .jumping
    }
    func debugJumpToCenter() {
        let target = platforms[currentIndex + 1].0.center
        let distance = simd_distance(SIMD2(character.position.x, character.position.z), target)
        var low: Float = 0, high: Float = 3
        for _ in 0..<32 {
            let middle = (low + high) / 2
            let path = JumpTrajectory(start: character.position, target: target, pressSeconds: middle)
            if path.horizontalSpeed * path.duration < distance { low = middle } else { high = middle }
        }
        debugJump(press: (low + high) / 2)
    }
    #endif
}
