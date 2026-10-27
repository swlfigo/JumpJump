import UIKit
import RealityKit
import AVFoundation

// Platform patterns and sounds are generated locally without bundled media.
final class AssetLibrary {
    private var textures: [String: TextureResource] = [:]
    private var players: [String: AVAudioPlayer] = [:]
    var soundEnabled = true

    func texture(_ name: String) -> TextureResource? {
        if let cached = textures[name] { return cached }
        guard name == "gray" || name == "box_top" else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { renderer in
            let context = renderer.cgContext
            if name == "gray" {
                context.setFillColor(UIColor(hex: 0xA8B0AA).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                for row in 0..<4 {
                    for column in 0..<4 {
                        let color: UInt32 = (row + column).isMultiple(of: 2) ? 0xD8DDD5 : 0xC5CDC4
                        context.setFillColor(UIColor(hex: color).cgColor)
                        context.fill(CGRect(x: column * 64 + 3, y: row * 64 + 3, width: 58, height: 58))
                    }
                }
            } else {
                context.setFillColor(UIColor(hex: 0xD9B584).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                context.setFillColor(UIColor(hex: 0xEEDFBD).cgColor)
                context.fill(CGRect(x: 104, y: 0, width: 48, height: 256))
                context.fill(CGRect(x: 0, y: 104, width: 256, height: 48))
                context.setFillColor(UIColor(hex: 0x73B6A0).cgColor)
                context.fill(CGRect(x: 92, y: 92, width: 72, height: 72))
                context.setStrokeColor(UIColor(hex: 0xE8E5DF).cgColor)
                context.setLineWidth(4)
                context.stroke(CGRect(x: 104, y: 104, width: 48, height: 48))
            }
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
        textures[name] = texture
        return texture
    }
    func topMaterial(_ name: String, fallback: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(color: fallback)
        if let texture = texture(name) {
            material.color = .init(tint: .white, texture: .init(texture))
        }
        return material
    }
    func play(_ name: String, loop: Bool = false) {
        guard soundEnabled else { return }
        if players[name] == nil, let data = GameAudio.data(for: name) {
            players[name] = try? AVAudioPlayer(data: data)
            players[name]?.prepareToPlay()
        }
        guard let player = players[name] else { return }
        player.stop()
        player.currentTime = 0
        player.numberOfLoops = loop ? -1 : 0
        player.volume = loop ? 0.3 : 0.65
        player.play()
    }
    func stop(_ name: String) { players[name]?.stop() }
    func stopAll() { players.values.forEach { $0.stop() } }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
