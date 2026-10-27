import Foundation
import simd

// Simulation world units are independent of the rendering layer.
struct SeededRandom {
    private(set) var seed: Int
    init(seed: Int) { self.seed = abs(seed % 233_280) }
    mutating func next() -> Float {
        seed = (9301 * seed + 49297) % 233280
        return Float(Int(Float(seed) / 233280 * 100)) / 100
    }
}

enum PlatformStyle: Int, CaseIterable {
    case mint, charcoal, tiled, parcel, cylinder
    var isRound: Bool { self == .cylinder }
}

struct PlatformSpec {
    let id: Int
    let center: SIMD2<Float> // world x,z
    let radius: Float
    let style: PlatformStyle
    func contains(_ point: SIMD2<Float>) -> Bool {
        let delta = point - center
        if style.isRound { return simd_length_squared(delta) <= radius * radius }
        return abs(delta.x) <= radius && abs(delta.y) <= radius
    }
}

struct PlatformGenerator {
    private var random: SeededRandom
    private var sequence = 0
    init(seed: Int) { random = SeededRandom(seed: seed) }
    mutating func next(after current: PlatformSpec, score: Int) -> PlatformSpec {
        sequence += 1
        let scale = 0.8 + random.next() * 0.2
        let radius = (scale * 5 * 100).rounded() / 1000
        // Simplified first-version distribution. Keep original spacing semantics:
        // gap is EDGE-to-EDGE, not center-to-center.
        let maxGap: Float = sequence < 3 ? 0.9 : 1.7
        let gap = 0.1 + random.next() * (maxGap - 0.1)
        let straight = random.next() > 0.5
        let distance = current.radius + gap + radius
        let center = current.center + (straight ? SIMD2(distance, 0) : SIMD2(0, -distance))
        let style: PlatformStyle = sequence % 5 == 0 ? .parcel : PlatformStyle(rawValue: Int(random.next() * 5))!
        return PlatformSpec(id: sequence, center: center, radius: radius, style: style)
    }
}

struct JumpTrajectory {
    let start: SIMD3<Float>
    let direction: SIMD2<Float>
    let horizontalSpeed: Float
    let verticalSpeed: Float
    let duration: Float
    static let gravity: Float = 72
    init(start: SIMD3<Float>, target: SIMD2<Float>, pressSeconds: Float) {
        self.start = start
        let delta = target - SIMD2(start.x, start.z)
        direction = simd_length_squared(delta) > 0.000001 ? simd_normalize(delta) : SIMD2(1, 0)
        let press = max(0, min(pressSeconds, 3))
        horizontalSpeed = min(press * 7, 15)
        verticalSpeed = min(13.5 + press * 1.5, 18)
        // Positive root of start.y + vy*t - g*t*t/2 = 0 (platform top y=0).
        duration = (verticalSpeed + sqrt(verticalSpeed * verticalSpeed + 2 * Self.gravity * max(start.y, 0))) / Self.gravity
    }
    func position(at time: Float) -> SIMD3<Float> {
        let horizontal = direction * horizontalSpeed * time
        return start + SIMD3(horizontal.x, verticalSpeed * time - 0.5 * Self.gravity * time * time, horizontal.y)
    }
    var landing: SIMD2<Float> { let p = position(at: duration); return SIMD2(p.x, p.z) }
    func hit(current: PlatformSpec, next: PlatformSpec) -> LandingResult {
        if next.contains(landing) {
            return simd_length_squared(landing - next.center) < 0.005 ? .perfect : .success
        }
        return current.contains(landing) ? .stayed : .miss
    }
}

enum LandingResult { case perfect, success, stayed, miss }

// Calculate a conservative landing corridor using the SAME capped trajectory
// as gameplay. The green interval leaves 20% of the target radius at each edge.
struct ForceGuide: Equatable {
    static let fullChargeDuration: Float = 1.5
    let targetID: Int
    let idealSeconds: Float
    let minimumSeconds: Float
    let maximumSeconds: Float

    init(start: SIMD3<Float>, target: PlatformSpec) {
        targetID = target.id
        let delta = target.center - SIMD2(start.x, start.z)
        let distance = simd_length(delta)
        let direction = distance > 0.000001 ? delta / distance : SIMD2<Float>(1, 0)
        let insetRadius = target.radius * 0.8
        let halfSpan = target.style.isRound ? insetRadius : insetRadius / max(abs(direction.x), abs(direction.y))
        func press(for desiredDistance: Float) -> Float {
            var low: Float = 0, high: Float = 3
            for _ in 0..<32 {
                let middle = (low + high) / 2
                let path = JumpTrajectory(start: start, target: target.center, pressSeconds: middle)
                if path.horizontalSpeed * path.duration < max(0, desiredDistance) { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
        idealSeconds = press(for: distance)
        minimumSeconds = press(for: distance - halfSpan)
        maximumSeconds = press(for: distance + halfSpan)
    }
}

// Platforms arrive from 2 world units above their top and bounce into place.
struct PlatformArrivalAnimation {
    static let duration: Float = 0.5
    static let startHeight: Float = 2
    static func height(at elapsed: Float) -> Float {
        let t = max(0, min(elapsed / duration, 1))
        return startHeight * (1 - bounceOut(t))
    }
    private static func bounceOut(_ progress: Float) -> Float {
        let n: Float = 7.5625, d: Float = 2.75
        var t = progress
        if t < 1 / d { return n * t * t }
        if t < 2 / d { t -= 1.5 / d; return n * t * t + 0.75 }
        if t < 2.5 / d { t -= 2.25 / d; return n * t * t + 0.9375 }
        t -= 2.625 / d
        return n * t * t + 0.984375
    }
}
