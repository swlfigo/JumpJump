import Foundation

// Original, mathematically synthesized game sounds; no bundled audio is required.
enum GameAudio {
    private static let sampleRate = 22_050

    private struct Tone {
        let start: Double
        let duration: Double
        let frequency: Double
        let endFrequency: Double
        let volume: Double
        let decay: Double

        init(_ frequency: Double, end: Double? = nil, start: Double = 0,
             duration: Double, volume: Double = 0.7, decay: Double = 4) {
            self.start = start
            self.duration = duration
            self.frequency = frequency
            self.endFrequency = end ?? frequency
            self.volume = volume
            self.decay = decay
        }

        func sample(at time: Double) -> Double {
            let t = time - start
            guard t >= 0, t < duration else { return 0 }
            let attack = min(t / 0.008, 1)
            let release = min((duration - t) / 0.04, 1)
            let envelope = pow(sin(attack * .pi / 2), 2)
                * pow(sin(release * .pi / 2), 2) * exp(-decay * t)
            let phase = 2 * Double.pi
                * (frequency * t + (endFrequency - frequency) * t * t / (2 * duration))
            let wave = 0.8 * sin(phase) + 0.15 * sin(2 * phase) + 0.05 * sin(3 * phase)
            return volume * envelope * wave
        }
    }

    static func data(for name: String) -> Data? {
        if name == "scale_loop" { return chargingLoop() }

        let tones: [Tone]
        switch name {
        case "start":
            tones = [
                Tone(523.25, duration: 0.24, volume: 0.5),
                Tone(659.25, start: 0.1, duration: 0.24, volume: 0.5),
                Tone(783.99, start: 0.2, duration: 0.3, volume: 0.55)
            ]
        case "scale_intro":
            tones = [Tone(165, end: 220, duration: 0.34, volume: 0.5, decay: 0)]
        case "success", "pop":
            tones = [Tone(660, end: 880, duration: 0.16, volume: 0.65, decay: 9)]
        case "fall":
            tones = [Tone(390, end: 110, duration: 0.43, volume: 0.6, decay: 3)]
        case "perfect":
            tones = rewardTones(combo: 1)
        default:
            guard name.hasPrefix("combo"),
                  let combo = Int(name.dropFirst(5)), (1...8).contains(combo) else { return nil }
            tones = rewardTones(combo: combo)
        }

        let duration = tones.map { $0.start + $0.duration }.max() ?? 0
        return waveData(duration: duration) { time in
            tones.reduce(0) { $0 + $1.sample(at: time) }
        }
    }

    private static func rewardTones(combo: Int) -> [Tone] {
        let root = 523.25 * pow(2, Double(combo - 1) / 12)
        return [
            Tone(root, duration: 0.2, volume: 0.6, decay: 7),
            Tone(root * 1.5, start: 0.065, duration: 0.26, volume: 0.48, decay: 7)
        ]
    }

    private static func chargingLoop() -> Data {
        // Every oscillator completes an integer number of cycles in 0.4 s,
        // including the amplitude modulation, so repeated buffers join smoothly.
        waveData(duration: 0.4) { time in
            let phase = 2 * Double.pi * time
            let pulse = 0.8 + 0.2 * cos(phase * 5)
            return 0.45 * pulse * (0.7 * sin(phase * 220)
                + 0.2 * sin(phase * 330) + 0.1 * sin(phase * 440))
        }
    }

    private static func waveData(duration: Double, sample: (Double) -> Double) -> Data {
        let frames = Int((duration * Double(sampleRate)).rounded())
        let byteCount = UInt32(frames * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(byteCount))
        data.append(contentsOf: "RIFF".utf8)
        appendWord(36 + byteCount, bytes: 4, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendWord(16, bytes: 4, to: &data)
        appendWord(1, bytes: 2, to: &data) // PCM
        appendWord(1, bytes: 2, to: &data) // Mono
        appendWord(UInt32(sampleRate), bytes: 4, to: &data)
        appendWord(UInt32(sampleRate * 2), bytes: 4, to: &data)
        appendWord(2, bytes: 2, to: &data)
        appendWord(16, bytes: 2, to: &data)
        data.append(contentsOf: "data".utf8)
        appendWord(byteCount, bytes: 4, to: &data)

        for frame in 0..<frames {
            let amplitude = tanh(sample(Double(frame) / Double(sampleRate))) * 0.75
            let value = Int16((amplitude * Double(Int16.max)).rounded())
            appendWord(UInt32(UInt16(bitPattern: value)), bytes: 2, to: &data)
        }
        return data
    }

    private static func appendWord(_ value: UInt32, bytes: Int, to data: inout Data) {
        for byte in 0..<bytes {
            data.append(UInt8(truncatingIfNeeded: value >> (byte * 8)))
        }
    }
}
