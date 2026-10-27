import Foundation
import simd

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
// Exercise the guide through the same trajectory/hit classifier used by play.
// Fractions deliberately use the public full-charge constant, not UI helpers.
func checkForceGuide(start: SIMD3<Float>, current: PlatformSpec, target: PlatformSpec) {
    let guide = ForceGuide(start: start, target: target)
    check(ForceGuide.fullChargeDuration == 1.5, "guide uses full 1.5-second charge scale")
    check(guide.targetID == target.id, "guide retains next target identity")
    check(guide.idealSeconds.isFinite, "guide ideal is finite")
    check(guide.minimumSeconds.isFinite, "guide minimum is finite")
    check(guide.maximumSeconds.isFinite, "guide maximum is finite")
    check(guide.minimumSeconds >= 0, "guide minimum is nonnegative")
    check(guide.minimumSeconds <= guide.idealSeconds, "guide minimum bounds ideal")
    check(guide.idealSeconds <= guide.maximumSeconds, "guide maximum bounds ideal")
    check(guide.maximumSeconds <= ForceGuide.fullChargeDuration, "guide safe range fits full charge")
    let idealFraction = guide.idealSeconds / ForceGuide.fullChargeDuration
    let minimumFraction = guide.minimumSeconds / ForceGuide.fullChargeDuration
    let maximumFraction = guide.maximumSeconds / ForceGuide.fullChargeDuration
    check(idealFraction > 0 && idealFraction <= 1, "guide center fraction is normalized")
    check(minimumFraction >= 0 && minimumFraction <= idealFraction, "guide lower fraction bounds center")
    check(maximumFraction >= idealFraction && maximumFraction <= 1, "guide upper fraction bounds center")
    let centerPath = JumpTrajectory(start: start, target: target.center, pressSeconds: guide.idealSeconds)
    check(centerPath.hit(current: current, next: target) == .perfect, "guide ideal hits next center perfectly")
    check(simd_length(centerPath.landing - target.center) < 0.0001, "guide ideal solves actual target center")

    // Include both endpoints, not just the forgiving center. The inset is
    // shape-specific: a circle's radial margin versus a square's edge margin.
    for sample in 0...10 {
        let fraction = Float(sample) / 10
        let seconds = guide.minimumSeconds + (guide.maximumSeconds - guide.minimumSeconds) * fraction
        let path = JumpTrajectory(start: start, target: target.center, pressSeconds: seconds)
        let result = path.hit(current: current, next: target)
        check(result == .success || result == .perfect, "every guide safe-range sample lands on next")
        let offset = path.landing - target.center
        let safeRadius = target.radius * 0.8
        let withinInset = target.style.isRound
            ? simd_length(offset) <= safeRadius + 0.0001
            : max(abs(offset.x), abs(offset.y)) <= safeRadius + 0.0001
        check(withinInset, "guide range reserves 20 percent radius at each edge")
    }

    let towardTarget = simd_normalize(target.center - SIMD2(start.x, start.z))
    let shiftedStart = start + SIMD3(towardTarget.x * 0.1, 0, towardTarget.y * 0.1)
    let shifted = ForceGuide(start: shiftedStart, target: target)
    check(shifted.idealSeconds < guide.idealSeconds, "moving 0.1 toward next reduces ideal seconds")
    let shiftedPath = JumpTrajectory(start: shiftedStart, target: target.center, pressSeconds: shifted.idealSeconds)
    check(shiftedPath.hit(current: current, next: target) == .perfect, "shifted guide still hits center perfectly")
}

var r1 = SeededRandom(seed: 1337)
var r2 = SeededRandom(seed: 1337)
for _ in 0..<100 {
    let a = r1.next(), b = r2.next()
    check(a == b, "seed determinism")
    check(a >= 0 && a < 1, "random range")
}
let first = PlatformSpec(id: 0, center: .zero, radius: 0.5, style: .mint)
var generator = PlatformGenerator(seed: 1337)
var previous = first
for i in 1...100 {
    let next = generator.next(after: previous, score: i)
    let delta = next.center - previous.center
    check((delta.x > 0 && delta.y == 0) || (delta.x == 0 && delta.y < 0), "two forward axes")
    let gap = simd_length(delta) - previous.radius - next.radius
    check(gap >= 0.099 && gap <= 1.701, "edge gap, not center distance")
    check(next.radius >= 0.4 && next.radius <= 0.5, "platform size")
    var low: Float = 0, high: Float = 3
    let start = SIMD3(previous.center.x, 0, previous.center.y)
    for _ in 0..<32 {
        let press = (low + high) / 2
        let path = JumpTrajectory(start: start, target: next.center, pressSeconds: press)
        if path.horizontalSpeed * path.duration < simd_length(delta) { low = press } else { high = press }
    }
    let path = JumpTrajectory(start: start, target: next.center, pressSeconds: (low + high) / 2)
    check(path.hit(current: previous, next: next) == .perfect, "reachable center")
    check(abs(path.position(at: path.duration).y) < 0.0001, "land at top")
    checkForceGuide(start: start, current: previous, target: next)
    previous = next
}
// Preserve the original seeded 100-platform checks above and broaden guide
// coverage across independent sequences, both forward axes and all styles.
for seed in [1, 42, 2026] {
    var guideGenerator = PlatformGenerator(seed: seed)
    var guideCurrent = first
    for score in 1...100 {
        let guideTarget = guideGenerator.next(after: guideCurrent, score: score)
        let start = SIMD3(guideCurrent.center.x, 0, guideCurrent.center.y)
        checkForceGuide(start: start, current: guideCurrent, target: guideTarget)
        guideCurrent = guideTarget
    }
}
// Off-axis actual positions distinguish square edge insets from circle insets;
// generated center-to-center hops alone would not expose that difference.
for style in [PlatformStyle.mint, .cylinder] {
    let obliqueTarget = PlatformSpec(id: 101, center: SIMD2(1.8, -0.8), radius: 0.4, style: style)
    checkForceGuide(start: SIMD3(0.1, 0, 0.15), current: first, target: obliqueTarget)
}
let target = PlatformSpec(id: 1, center: SIMD2(2, 0), radius: 0.4, style: .cylinder)
check(target.contains(SIMD2(2, 0)), "cylinder center")
check(!target.contains(SIMD2(2.35, 0.35)), "cylinder excludes square corner")
let zero = JumpTrajectory(start: .zero, target: target.center, pressSeconds: 0)
check(zero.hit(current: first, next: target) == .stayed, "zero charge stays")
let miss = JumpTrajectory(start: .zero, target: target.center, pressSeconds: 3)
check(miss.hit(current: first, next: target) == .miss, "overcharge misses")
let elevated = JumpTrajectory(start: SIMD3(0, 0.2, 0), target: target.center, pressSeconds: 0.5)
check(abs(elevated.position(at: elevated.duration).y) < 0.0001, "height-aware trajectory")
check(elevated.direction.x.isFinite, "finite direction")
let noDirection = JumpTrajectory(start: .zero, target: .zero, pressSeconds: 0)
check(noDirection.direction.x.isFinite, "zero-length direction guard")
check(PlatformArrivalAnimation.height(at: 0) == 2, "arrival begins above platform")
check(PlatformArrivalAnimation.height(at: 0.5) == 0, "arrival lands in half a second")
check(PlatformArrivalAnimation.height(at: 2) == 0, "settled arrival stays finished")
check(PlatformArrivalAnimation.height(at: 0.25) > PlatformArrivalAnimation.height(at: 0.5 / 2.75), "arrival bounces after first impact")
for frame in 0...120 {
    let height = PlatformArrivalAnimation.height(at: Float(frame) / 120 * 0.5)
    check(height >= -0.00001 && height <= 2.00001, "bounce remains above landing surface")
}
print("PASS: \(checks) core checks (seed, spacing, landing, failure and arrival animation)")
