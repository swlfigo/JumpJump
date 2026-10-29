import UIKit
import RealityKit
import simd

// The chess-piece figure shared by the local player and remote racers.
enum Figure {
    // Online player colors; the server hands each player a distinct slot so
    // everyone, the player included, sees the same color. Avoids the platform
    // mint and tans; the last slot is the classic single-player charcoal.
    static let palette: [UInt32] = [0xD9583B, 0x3D7DC8, 0x8E5BC8, 0xD4A62A, 0xD9609A, 0x2E9FC4, 0x8A5A3C, 0x343946]
    static func color(_ slot: Int) -> UIColor { UIColor(hex: palette[abs(slot) % palette.count]) }

    static func build(into visual: Entity, body: UIColor, cap: UIColor) {
        let bodyMaterial = SimpleMaterial(color: body, roughness: 0.8, isMetallic: false)
        let torso = ModelEntity(mesh: .generateCylinder(height: 0.31, radius: 0.105), materials: [bodyMaterial])
        torso.position.y = 0.155
        visual.addChild(torso)
        let neck = ModelEntity(mesh: .generateCylinder(height: 0.07, radius: 0.055), materials: [bodyMaterial])
        neck.position.y = 0.34
        visual.addChild(neck)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.095),
                               materials: [SimpleMaterial(color: UIColor(hex: 0xE3B787), roughness: 0.65, isMetallic: false)])
        head.position.y = 0.445
        visual.addChild(head)
        let hat = ModelEntity(mesh: .generateCylinder(height: 0.06, radius: 0.092),
                              materials: [SimpleMaterial(color: cap, roughness: 0.8, isMetallic: false)])
        hat.position.y = 0.51
        visual.addChild(hat)
    }
}

struct RemoteLabel {
    let id: Int
    let name: String
    let color: UIColor
    let point: CGPoint?
}

// A remote racer replayed from the server's authoritative jumps. It mirrors the
// local character's charge/flip/settle/fall animation but never decides an
// outcome: the landing point and result always come from the server.
final class RemoteAvatar {
    let id: Int
    let name: String
    let color: UIColor
    let root = Entity()
    let shadow = ModelEntity()
    private let visual = Entity()
    private(set) var position = SIMD3<Float>.zero
    private(set) var index = 0 // absolute platform index it stands on
    private(set) var isOut = false
    private enum Phase { case idle, charging, jumping, settling, falling, hidden }
    private var phase = Phase.idle
    private var elapsed: Float = 0
    private var trajectory: JumpTrajectory?
    private var landing = SIMD2<Float>.zero
    private var result = LandingResult.stayed

    init(id: Int, name: String, color: UIColor) {
        self.id = id
        self.name = name
        self.color = color
        Figure.build(into: visual, body: color, cap: color)
        root.addChild(visual)
        // Translucent so the local player always reads through a crowd.
        root.components.set(OpacityComponent(opacity: 0.5))
        var shadowMaterial = UnlitMaterial(color: UIColor.black)
        shadowMaterial.blending = .transparent(opacity: 0.08)
        shadow.model = ModelComponent(mesh: .generateSphere(radius: 0.15), materials: [shadowMaterial])
        shadow.scale = SIMD3(1, 0.01, 0.65)
        sync()
    }

    var isVisible: Bool { phase != .hidden }
    var isInMotion: Bool { phase == .jumping || phase == .falling }
    var labelAnchor: SIMD3<Float> { position + SIMD3(0, 0.75, 0) }

    func charge() {
        guard phase == .idle || phase == .settling else { return }
        phase = .charging
        elapsed = 0
    }

    func jump(pressMs: Int, landing: SIMD2<Float>, result: LandingResult, target: SIMD2<Float>) {
        if phase == .jumping { land() } // a quick follow-up jump snaps the last one
        trajectory = JumpTrajectory(start: position, target: target, pressSeconds: Float(pressMs) / 1000)
        self.landing = landing
        self.result = result
        visual.scale = .one
        elapsed = 0
        phase = .jumping
        if result == .perfect || result == .success { index += 1 }
        if result == .miss { isOut = true }
    }

    // Forfeits (idle, disconnect, leave) simply vanish; falls play out first.
    func remove() {
        isOut = true
        phase = .hidden
        sync()
    }

    func update(delta dt: Float) {
        switch phase {
        case .charging:
            elapsed += dt
            let compression = min(elapsed / 1.5, 1) * 0.35
            visual.scale = SIMD3(1 + compression * 0.2, 1 - compression, 1 + compression * 0.2)
        case .jumping:
            guard let trajectory else { break }
            elapsed += dt
            let t = min(elapsed, trajectory.duration)
            position = trajectory.position(at: t)
            let axis = SIMD3(trajectory.direction.y, 0, -trajectory.direction.x)
            visual.orientation = simd_quatf(angle: t / trajectory.duration * .pi * 2, axis: axis)
            if elapsed >= trajectory.duration { land() }
        case .settling:
            elapsed += dt
            let squash = sin(min(elapsed / 0.18, 1) * .pi) * 0.18
            visual.scale = SIMD3(1 + squash * 0.2, 1 - squash, 1 + squash * 0.2)
            if elapsed >= 0.2 { visual.scale = .one; phase = .idle }
        case .falling:
            elapsed += dt
            position.y -= (1 + elapsed * 10) * dt
            visual.orientation = simd_quatf(angle: min(elapsed * 4, 1.7), axis: SIMD3(1, 0, 0.5))
            if elapsed > 0.65 { phase = .hidden }
        case .idle, .hidden: break
        }
        sync()
    }

    private func land() {
        visual.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        position = SIMD3(landing.x, 0, landing.y)
        elapsed = 0
        phase = result == .miss ? .falling : .settling
    }

    private func sync() {
        root.position = position
        root.isEnabled = phase != .hidden
        shadow.isEnabled = phase != .hidden && phase != .falling
        shadow.position = SIMD3(position.x, 0.009, position.z)
        let shrinking = max(0.45, 1 - max(position.y, 0) * 0.3)
        shadow.scale = SIMD3(shrinking, 0.01, shrinking * 0.65)
    }
}
