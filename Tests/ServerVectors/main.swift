import Foundation
import simd

// Golden vectors for the Go server port (JumpJumpServer/internal/game).
// Every Float is exported as its IEEE-754 bit pattern so Go can compare exactly.
// Build: swiftc -O JumpJump/GameLogic.swift Tests/ServerVectors/main.swift

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ low: Float, _ high: Float) -> Float { low + unit() * (high - low) }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
}

struct PlatformJSON: Codable {
    let id: Int, center: [UInt32], radius: UInt32, style: Int
    init(_ spec: PlatformSpec) {
        id = spec.id; center = bits(spec.center); radius = spec.radius.bitPattern; style = spec.style.rawValue
    }
}
struct GeneratorCase: Codable { let seed: Int; let platforms: [PlatformJSON] }
struct ContainsCase: Codable { let platform: PlatformJSON; let point: [UInt32]; let contains: Bool }
struct TrajectoryCase: Codable {
    let start: [UInt32], target: [UInt32], press: UInt32
    let direction: [UInt32], horizontalSpeed: UInt32, verticalSpeed: UInt32, duration: UInt32, landing: [UInt32]
    let current: PlatformJSON, next: PlatformJSON, result: String
}
struct GameStep: Codable { let pressMs: Int; let landing: [UInt32]; let result: String; let score: Int; let combo: Int; let index: Int }
struct GameCase: Codable { let seed: Int; let steps: [GameStep] }
struct Vectors: Codable {
    let generator: [GeneratorCase], contains: [ContainsCase], trajectories: [TrajectoryCase], games: [GameCase]
}

func bits(_ value: SIMD2<Float>) -> [UInt32] { [value.x.bitPattern, value.y.bitPattern] }
func bits(_ value: SIMD3<Float>) -> [UInt32] { [value.x.bitPattern, value.y.bitPattern, value.z.bitPattern] }

let firstPlatform = PlatformSpec(id: 0, center: .zero, radius: 0.5, style: .mint)
var rng = SplitMix64(state: 20261028)

func randomPlatform(id: Int, center: SIMD2<Float>) -> PlatformSpec {
    PlatformSpec(id: id, center: center, radius: rng.range(0.4, 0.5), style: PlatformStyle(rawValue: rng.int(5))!)
}

// Seeds outside the game's 1..<233280 range still exercise SeededRandom's normalization.
var generator: [GeneratorCase] = []
for seed in [1, 1337, 233_279, 0, -5, 10_000_000_007] + (0..<6).map({ _ in 1 + rng.int(233_279) }) {
    var platformGenerator = PlatformGenerator(seed: seed)
    var platforms = [firstPlatform]
    for _ in 0..<100 { platforms.append(platformGenerator.next(after: platforms.last!, score: 0)) }
    generator.append(GeneratorCase(seed: seed, platforms: platforms.map(PlatformJSON.init)))
}

// Points one ulp around the edges pin down the inclusive `<=` boundary checks.
var contains: [ContainsCase] = []
for _ in 0..<600 {
    let platform = randomPlatform(id: 0, center: SIMD2(rng.range(-40, 40), rng.range(-40, 40)))
    func edge() -> Float {
        let base = platform.style.isRound ? platform.radius * 0.70710677 : platform.radius
        let nudged = Float(bitPattern: UInt32(Int(base.bitPattern) + rng.int(5) - 2))
        return rng.int(2) == 0 ? nudged : -nudged
    }
    let offset: SIMD2<Float>
    switch rng.int(3) {
    case 0: offset = SIMD2(edge(), edge())
    case 1: offset = SIMD2(edge(), rng.range(-platform.radius, platform.radius))
    default: offset = SIMD2(rng.range(-1.3, 1.3), rng.range(-1.3, 1.3)) * platform.radius
    }
    let point = platform.center + offset
    contains.append(ContainsCase(platform: PlatformJSON(platform), point: bits(point), contains: platform.contains(point)))
}

var trajectories: [TrajectoryCase] = []
for index in 0..<1000 {
    let start = SIMD3<Float>(rng.range(-60, 60), index % 10 == 0 ? rng.range(0, 2) : 0, rng.range(-60, 60))
    let offset: SIMD2<Float>
    switch rng.int(4) {
    case 0: offset = SIMD2(rng.range(0, 6), 0)
    case 1: offset = SIMD2(0, -rng.range(0, 6))
    case 2: let angle = rng.range(0, 2 * .pi); offset = SIMD2(cos(angle), sin(angle)) * rng.range(0, 6)
    default: offset = SIMD2(rng.range(-0.002, 0.002), rng.range(-0.002, 0.002)) // near the degenerate-direction threshold
    }
    let current = randomPlatform(id: 1, center: SIMD2(start.x, start.z))
    let next = randomPlatform(id: 2, center: SIMD2(start.x, start.z) + offset)
    let press: Float
    switch rng.int(5) {
    case 0: press = Float(rng.int(3501)) / 1000
    case 1: press = rng.range(-0.5, 3.5)
    case 2: press = [0, 1.5, 3][rng.int(3)]
    default:
        let guide = ForceGuide(start: start, target: next)
        press = guide.idealSeconds + rng.range(-1, 1) * (guide.maximumSeconds - guide.minimumSeconds)
    }
    let path = JumpTrajectory(start: start, target: next.center, pressSeconds: press)
    trajectories.append(TrajectoryCase(
        start: bits(start), target: bits(next.center), press: press.bitPattern,
        direction: bits(path.direction), horizontalSpeed: path.horizontalSpeed.bitPattern,
        verticalSpeed: path.verticalSpeed.bitPattern, duration: path.duration.bitPattern, landing: bits(path.landing),
        current: PlatformJSON(current), next: PlatformJSON(next), result: "\(path.hit(current: current, next: next))"))
}

// Mirrors GameRenderer.resolveLanding with protocol-style millisecond presses,
// so drift from short hops carries into later jumps exactly as in play.
var games: [GameCase] = []
for _ in 0..<30 {
    let seed = 1 + rng.int(233_279)
    var platformGenerator = PlatformGenerator(seed: seed)
    var platforms = [firstPlatform, platformGenerator.next(after: firstPlatform, score: 0)]
    var index = 0, score = 0, combo = 0
    var position = SIMD3<Float>.zero
    var steps: [GameStep] = []
    for _ in 0..<120 {
        let next = platforms[index + 1]
        let guide = ForceGuide(start: position, target: next)
        let spread = guide.maximumSeconds - guide.minimumSeconds
        let roll = rng.unit()
        let seconds: Float
        if roll < 0.25 { seconds = guide.idealSeconds }
        else if roll < 0.30 { seconds = rng.range(0, 0.15) }
        else if roll < 0.32 { seconds = rng.range(2, 3.2) }
        else if roll < 0.36 { seconds = guide.idealSeconds + rng.range(-0.8, 0.8) * spread }
        else { seconds = guide.idealSeconds + rng.range(-0.35, 0.35) * spread }
        let pressMs = max(0, Int((seconds * 1000).rounded()))
        let path = JumpTrajectory(start: position, target: next.center, pressSeconds: Float(pressMs) / 1000)
        let result = path.hit(current: platforms[index], next: next)
        position = SIMD3(path.landing.x, 0, path.landing.y)
        switch result {
        case .perfect, .success:
            if result == .perfect { combo += 1; score += combo * 2 } else { combo = 0; score += 1 }
            index += 1
            platforms.append(platformGenerator.next(after: platforms[index], score: score))
        case .stayed: break
        case .miss: combo = 0
        }
        steps.append(GameStep(pressMs: pressMs, landing: bits(path.landing), result: "\(result)", score: score, combo: combo, index: index))
        if result == .miss { break }
    }
    games.append(GameCase(seed: seed, steps: steps))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let data = try encoder.encode(Vectors(generator: generator, contains: contains, trajectories: trajectories, games: games))
FileHandle.standardOutput.write(data)
let counts = Dictionary(grouping: trajectories.map(\.result) + games.flatMap { $0.steps.map(\.result) }, by: { $0 }).mapValues(\.count)
FileHandle.standardError.write("vectors: \(generator.count) seeds, \(contains.count) contains, \(trajectories.count) trajectories, \(games.count) games (\(games.map(\.steps.count).reduce(0, +)) steps); results \(counts.sorted { $0.key < $1.key })\n".data(using: .utf8)!)
