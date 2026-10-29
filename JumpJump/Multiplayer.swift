import Foundation
import Network
import simd

// LAN multiplayer client for JumpJumpServer; see its docs/protocol.md.

struct LobbyPlayer: Decodable, Equatable {
    let playerID: Int
    let name: String
    let ready: Bool
    let color: Int? // palette slot from the server; absent from older servers
}

// A room on the server's list; joining a locked one needs its password.
struct RoomInfo: Decodable, Equatable {
    let roomID: Int
    let host: String
    let players: Int
    let maxPlayers: Int
    let locked: Bool
    let racing: Bool
}

struct RankEntry: Decodable {
    let playerID: Int
    let name: String
    let score: Int
    let status: String
}

// Every server message decodes into this; fields are present per `type`.
struct ServerMessage: Decodable {
    let type: String
    var rooms: [RoomInfo]?
    var playerID: Int?
    var players: [LobbyPlayer]?
    var seed: Int?
    var countdownMs: Int?
    var seq: Int?
    var pressMs: Int?
    var landingBits: [UInt32]?
    var result: String?
    var score: Int?
    var secondsLeft: Int?
    var reason: String?
    var ranking: [RankEntry]?
    var code: String?
    var message: String?
}

struct ClientMessage: Encodable {
    let type: String
    var name: String?
    var roomID: Int?
    var password: String?
    var seq: Int?
    var pressMs: Int?
}

struct LANServer: Equatable {
    let name: String
    let urls: [URL]
}

// Finds servers advertising _jumpjump._tcp. Their TXT record lists LAN
// addresses; connecting to those avoids a slow mDNS host-name lookup.
final class ServerBrowser {
    var onChange: (([LANServer]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_jumpjump._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = results.compactMap { result -> LANServer? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata,
                      let port = txt["port"], let addrs = txt["addrs"] else { return nil }
                let path = txt["path"] ?? "/ws"
                let urls = addrs.split(separator: ",").compactMap { URL(string: "ws://\($0):\(port)\(path)") }
                return urls.isEmpty ? nil : LANServer(name: name, urls: urls)
            }
            self?.onChange?(servers.sorted { $0.name < $1.name })
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

// One WebSocket connection; every callback runs on the main queue.
final class MultiplayerClient {
    var onMessage: ((ServerMessage) -> Void)?
    var onClose: ((String) -> Void)?
    private var connection: NWConnection?
    private var isOpen = false

    // Tries each address in turn until one connects.
    func connect(to urls: [URL]) {
        disconnect()
        guard let url = urls.first else { onClose?("无法连接服务器（请确认在同一 Wi-Fi，并允许访问本地网络）"); return }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 4
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.isOpen = true
                self.receive(on: connection)
            case .waiting, .failed:
                if self.isOpen { self.close("与服务器的连接已断开"); return }
                connection.cancel()
                self.connection = nil
                self.connect(to: Array(urls.dropFirst()))
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: ClientMessage) {
        guard isOpen, let connection, let data = try? JSONEncoder().encode(message) else { return }
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isOpen = false
    }

    // Sends a last message and closes once it is on the wire; nothing more is delivered.
    func finish(with message: ClientMessage) {
        guard isOpen, let connection, let data = try? JSONEncoder().encode(message) else { disconnect(); return }
        self.connection = nil
        isOpen = false
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func close(_ reason: String) {
        disconnect()
        onClose?(reason)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.connection === connection else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close { self.close("与服务器的连接已断开"); return }
            if let data, let message = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                self.onMessage?(message)
            }
            if self.connection === connection { self.receive(on: connection) }
        }
    }
}

struct Standing {
    let playerID: Int
    let name: String
    let color: Int
    let isSelf: Bool
    var score = 0
    var status: String? // nil while racing; otherwise the server's out reason
}

// Bridges the server and the renderer: forwards local input, replays remote
// racers, and reports lobby/match state for the UI.
final class OnlineMatch {
    let client = MultiplayerClient()
    private let game: GameRenderer
    private(set) var playerID: Int?
    private(set) var players: [LobbyPlayer] = []
    private(set) var isRacing = false
    private(set) var hasRaced = false // a rematch room, not the first lobby
    private var standings: [Int: Standing] = [:]
    private var pending: [Int: (pressMs: Int, landing: SIMD2<Float>, retries: Int)] = [:]
    private var matchToken = 0
    private(set) var desyncs = 0

    var onRooms: (([RoomInfo]) -> Void)?
    var onRemoved: ((String) -> Void)? // taken out of the room for not readying
    var onLobby: (([LobbyPlayer]) -> Void)?
    var onStart: ((_ countdown: TimeInterval) -> Void)?
    var onStandings: (([Standing]) -> Void)?
    var onNotice: ((String) -> Void)?
    var onReadyWarning: ((_ secondsLeft: Int) -> Void)?
    var onResult: (([RankEntry]) -> Void)?
    var onClosed: ((String) -> Void)?

    init(game: GameRenderer) {
        self.game = game
        client.onMessage = { [weak self] in self?.handle($0) }
        client.onClose = { [weak self] reason in
            guard let self else { return }
            self.isRacing = false
            self.onClosed?(reason)
        }
        game.onChargeBegan = { [weak self] seq in self?.client.send(ClientMessage(type: "charge", seq: seq)) }
        game.onJumpReleased = { [weak self] seq, pressMs, landing in
            self?.pending[seq] = (pressMs, landing, 0)
            self?.client.send(ClientMessage(type: "jump", seq: seq, pressMs: pressMs))
        }
    }

    // The server sends its room list once connected.
    func connect(to server: LANServer) {
        playerID = nil
        client.connect(to: server.urls)
    }

    func disconnect() { client.disconnect() }

    // An empty password leaves the room open to everyone.
    func create(name: String, password: String) {
        client.send(ClientMessage(type: "create", name: name, password: password))
    }

    func join(room: Int, name: String, password: String) {
        client.send(ClientMessage(type: "join", name: name, roomID: room, password: password))
    }

    func ready() { client.send(ClientMessage(type: "ready")) }

    // Back to the room list on the same connection.
    func leaveRoom() {
        client.send(ClientMessage(type: "leave"))
        playerID = nil
        players = []
        hasRaced = false
    }

    func leave() {
        client.finish(with: ClientMessage(type: "leave"))
        matchToken += 1
        isRacing = false
        game.onChargeBegan = nil
        game.onJumpReleased = nil
    }

    private func handle(_ message: ServerMessage) {
        switch message.type {
        case "rooms": // only sent while outside any room
            playerID = nil
            players = []
            hasRaced = false
            onRooms?(message.rooms ?? [])
        case "welcome":
            playerID = message.playerID
            players = message.players ?? []
            hasRaced = false
            onLobby?(players)
        case "lobby":
            players = message.players ?? []
            onLobby?(players)
        case "start":
            start(seed: message.seed ?? 1, countdown: TimeInterval(message.countdownMs ?? 0) / 1000)
        case "charge":
            if let id = message.playerID { game.remoteCharged(id: id) }
        case "jumped":
            jumped(message)
        case "readyWarning":
            onReadyWarning?(message.secondsLeft ?? 0)
        case "idleWarning":
            onNotice?("\(message.secondsLeft ?? 0) 秒内不起跳将判负")
        case "out":
            out(message)
        case "result":
            isRacing = false
            onResult?(message.ranking ?? [])
        case "error":
            rejected(code: message.code ?? "", message: message.message ?? "")
        default: break
        }
    }

    private func start(seed: Int, countdown: TimeInterval) {
        isRacing = true
        hasRaced = true
        pending.removeAll()
        game.isOnline = true
        game.restart(seed: seed)
        game.isInputLocked = true
        standings.removeAll()
        for (index, player) in players.enumerated() {
            let color = player.color ?? index
            let isSelf = player.playerID == playerID
            standings[player.playerID] = Standing(playerID: player.playerID, name: player.name, color: color, isSelf: isSelf)
            if isSelf {
                game.setSelfColor(Figure.color(color))
            } else {
                game.addRemote(id: player.playerID, name: player.name, color: Figure.color(color))
            }
        }
        publishStandings()
        onStart?(countdown)
        matchToken += 1
        let token = matchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + countdown) { [weak self] in
            guard let self, self.matchToken == token else { return }
            self.game.isInputLocked = false
        }
    }

    private func jumped(_ message: ServerMessage) {
        guard let id = message.playerID, let bits = message.landingBits, bits.count == 2,
              let result = LandingResult(wire: message.result ?? "") else { return }
        let landing = SIMD2(Float(bitPattern: bits[0]), Float(bitPattern: bits[1]))
        if id == playerID {
            // Both sides run the same float32 math, so this should never fire.
            if let seq = message.seq, let predicted = pending.removeValue(forKey: seq),
               predicted.landing.x.bitPattern != bits[0] || predicted.landing.y.bitPattern != bits[1] {
                desyncs += 1
                onNotice?("与服务器结果不一致（第 \(seq) 跳）")
            }
        } else {
            game.remoteJumped(id: id, pressMs: message.pressMs ?? 0, landing: landing, result: result)
        }
        update(id) { $0.score = message.score ?? $0.score }
    }

    private func out(_ message: ServerMessage) {
        guard let id = message.playerID, let reason = message.reason else { return }
        // Falls already play out from the jump itself; forfeits just vanish.
        if reason != "fell", id != playerID { game.removeRemote(id: id) }
        let name = standings[id]?.name ?? "玩家"
        switch (id == playerID, reason) {
        case (true, "idle"): onNotice?("长时间未起跳，已判负 · 观战中")
        case (false, "idle"): onNotice?("\(name) 挂机判负")
        case (false, "disconnected"): onNotice?("\(name) 断线判负")
        case (false, "left"): onNotice?("\(name) 离开了对局")
        default: break
        }
        update(id) { $0.status = reason }
    }

    private func rejected(code: String, message: String) {
        // Wi-Fi jitter can make an honest jump look early. The landing depends
        // only on the press, so resending the same jump a moment later is safe.
        if code == "too_early", let seq = pending.keys.min(), let jump = pending[seq], jump.retries < 3 {
            pending[seq]?.retries += 1
            let token = matchToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.matchToken == token, self.pending[seq] != nil else { return }
                self.client.send(ClientMessage(type: "jump", seq: seq, pressMs: jump.pressMs))
            }
            return
        }
        // The connection stays open: the server moves us back to the room list.
        if code == "ready_timeout" { onRemoved?("长时间未准备，已退出房间"); return }
        let text: String
        switch code {
        case "room_full": text = "房间已满"
        case "room_busy": text = "该房间正在对局中，请稍后再来"
        case "no_room": text = "房间已经不在了"
        case "wrong_password": text = "密码不对"
        case "bad_password": text = "密码最多 16 个字"
        case "bad_name": text = "昵称需要 1-16 个字"
        default: text = "服务器拒绝：\(message)"
        }
        onNotice?(text)
    }

    private func update(_ id: Int, _ change: (inout Standing) -> Void) {
        guard standings[id] != nil else { return }
        change(&standings[id]!)
        publishStandings()
    }

    private func publishStandings() {
        onStandings?(standings.values.sorted { ($0.score, -$0.playerID) > ($1.score, -$1.playerID) })
    }
}

extension LandingResult {
    init?(wire: String) {
        switch wire {
        case "perfect": self = .perfect
        case "success": self = .success
        case "stayed": self = .stayed
        case "miss": self = .miss
        default: return nil
        }
    }
}
