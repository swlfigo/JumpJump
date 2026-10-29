import UIKit

// Sheet for finding a LAN server, picking or creating a room and readying up.
// It only collects input; GameViewController wires it to the OnlineMatch.
final class LobbyViewController: UIViewController {
    var onConnect: ((LANServer) -> Void)?
    var onCreate: ((_ name: String, _ password: String) -> Void)?
    var onJoin: ((_ roomID: Int, _ name: String, _ password: String) -> Void)?
    var onReady: (() -> Void)?
    var onLeave: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    var onClose: (() -> Void)?
    private enum Stage { case servers, rooms, room }
    private var stage = Stage.servers
    private var autoConnect = true // until the player has been past the server list once
    private let browser = ServerBrowser()
    private var servers: [LANServer] = []
    private var selected: LANServer?
    private var rooms: [RoomInfo] = []
    private let statusLabel = UILabel()
    private let serverStack = UIStackView()
    private let addressField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let nameField = UITextField()
    private let roomScroll = UIScrollView()
    private let roomStack = UIStackView()
    private let passwordField = UITextField()
    private let createButton = UIButton(type: .system)
    private let serversButton = UIButton(type: .system)
    private let playersTable = PlayerTable(fontSize: 16, noteWidth: 52)
    private let readyButton = UIButton(type: .system)
    private let leaveButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var readyCountdown: Int? // seconds left before the server removes us
    private lazy var stageViews: [Stage: [UIView]] = [
        .servers: [serverStack, addressField, connectButton, closeButton],
        .rooms: [nameField, roomScroll, passwordField, createButton, serversButton, closeButton],
        .room: [playersTable, readyButton, leaveButton]
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0xE8E5DF)
        let title = UILabel()
        title.text = "局域网联机"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = UIColor(hex: 0x303943)
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = UIColor(hex: 0x48535A)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "onlineStatus"
        serverStack.axis = .vertical
        serverStack.spacing = 8
        configureField(addressField, placeholder: "或手动输入地址，如 192.168.1.10:7788", identifier: "onlineAddress")
        addressField.keyboardType = .URL
        configureField(nameField, placeholder: "昵称", identifier: "onlineName")
        nameField.text = UserDefaults.standard.string(forKey: "onlineName") ?? "玩家\(Int.random(in: 100...999))"
        roomStack.axis = .vertical
        roomStack.spacing = 8
        roomScroll.addSubview(roomStack)
        configureField(passwordField, placeholder: "房间密码（可不填，填了凭密码加入）", identifier: "onlinePassword")
        playersTable.accessibilityIdentifier = "onlinePlayers"
        configureButton(connectButton, title: "连接服务器", identifier: "onlineConnect", action: #selector(connect as () -> Void))
        configureButton(createButton, title: "创建房间", identifier: "onlineCreate", action: #selector(create))
        configureButton(serversButton, title: "换服务器", identifier: "onlineServers", action: #selector(switchServer))
        configureButton(readyButton, title: "准备", identifier: "onlineReady", action: #selector(ready))
        configureButton(leaveButton, title: "离开房间", identifier: "onlineLeave", action: #selector(leave))
        configureButton(closeButton, title: "返回首页", identifier: "onlineClose", action: #selector(close))
        let stack = UIStackView(arrangedSubviews: [title, statusLabel, serverStack, addressField, connectButton, nameField, roomScroll,
                                                   passwordField, createButton, serversButton, playersTable, readyButton, leaveButton,
                                                   closeButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(22, after: statusLabel)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        roomStack.translatesAutoresizingMaskIntoConstraints = false
        // The room list is as tall as its rooms, scrolling once there are many.
        let fitRooms = roomScroll.heightAnchor.constraint(equalTo: roomStack.heightAnchor)
        fitRooms.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            roomStack.topAnchor.constraint(equalTo: roomScroll.contentLayoutGuide.topAnchor),
            roomStack.bottomAnchor.constraint(equalTo: roomScroll.contentLayoutGuide.bottomAnchor),
            roomStack.leadingAnchor.constraint(equalTo: roomScroll.contentLayoutGuide.leadingAnchor),
            roomStack.trailingAnchor.constraint(equalTo: roomScroll.contentLayoutGuide.trailingAnchor),
            roomStack.widthAnchor.constraint(equalTo: roomScroll.frameLayoutGuide.widthAnchor),
            fitRooms,
            roomScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 250)
        ])
        setStage(.servers)
        showStatus("正在搜索同一 Wi-Fi 下的服务器…")
        browser.onChange = { [weak self] in self?.show(servers: $0) }
        browser.start()
        #if DEBUG
        // UI tests point the lobby at a private server instead of Bonjour.
        addressField.text = ProcessInfo.processInfo.environment["JUMPJUMP_SERVER"]
        #endif
        // Async: a rematch lobby goes straight to the room view first, which
        // disarms the automatic connect.
        DispatchQueue.main.async { [weak self] in self?.connectAutomatically() }
        // Bonjour reports nothing when it finds nothing; say so after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.stage == .servers, self.servers.isEmpty,
                  self.statusLabel.text?.hasPrefix("正在搜索") == true else { return }
            self.showStatus(Self.noServerHint)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        browser.stop()
    }

    func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.textColor = UIColor(hex: 0x48535A)
    }

    // nil clears the warning once the player readies (or the room moves on).
    func showReadyCountdown(_ seconds: Int?) {
        readyCountdown = seconds
        guard stage == .room else { return }
        guard let seconds else { showStatus(Self.lobbyHint); return }
        statusLabel.text = "还没准备，\(seconds) 秒后将自动退出房间"
        statusLabel.textColor = UIColor(hex: 0xC4502F)
    }

    private static let lobbyHint = "全员准备后自动开始（至少 2 人）"
    private static let roomsHint = "点一个房间加入，或创建新房间"
    private static let noServerHint = "没有发现服务器。房间开在服务器上：请先在电脑上运行 jumpjump-server，并让手机和电脑连同一 Wi-Fi，或手动输入地址。"

    // The server's room list, sent whenever it changes while we are outside a room.
    func showRooms(_ rooms: [RoomInfo]) {
        self.rooms = rooms
        if stage != .rooms {
            setStage(.rooms)
            showStatus(Self.roomsHint)
        }
        roomStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if rooms.isEmpty {
            let empty = UILabel()
            empty.text = "还没有房间，创建一个吧"
            empty.font = .systemFont(ofSize: 15)
            empty.textColor = UIColor(hex: 0x7A8288)
            empty.textAlignment = .center
            roomStack.addArrangedSubview(empty)
        }
        for room in rooms {
            let full = room.players >= room.maxPlayers
            let title = "\(room.host) 的房间"
            let state = room.racing ? "对局中" : full ? "已满" : "等待中"
            var config = UIButton.Configuration.tinted()
            config.title = title
            config.subtitle = "\(room.players)/\(room.maxPlayers) 人 · \(state)"
            config.image = room.locked ? UIImage(systemName: "lock.fill") : nil
            config.imagePlacement = .trailing
            config.imagePadding = 8
            config.titleAlignment = .leading
            config.baseBackgroundColor = UIColor(hex: 0x73B6A0)
            config.baseForegroundColor = UIColor(hex: 0x365B4D)
            config.cornerStyle = .large
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.isEnabled = !room.racing && !full
            button.tag = room.roomID
            button.accessibilityIdentifier = "room_\(room.host)"
            button.accessibilityLabel = title + (room.locked ? "，需要密码" : "")
            button.accessibilityValue = config.subtitle
            button.addTarget(self, action: #selector(pickRoom(_:)), for: .touchUpInside)
            roomStack.addArrangedSubview(button)
        }
    }

    func showLobby(_ players: [LobbyPlayer], selfID: Int?) {
        setStage(.room)
        if readyCountdown == nil { showStatus(Self.lobbyHint) }
        playersTable.show(players.enumerated().map { index, player in
            let isSelf = player.playerID == selfID
            return PlayerTable.Row(color: Figure.color(player.color ?? index), name: player.name + (isSelf ? "（你）" : ""),
                                   isSelf: isSelf, note: player.ready ? "已准备" : "未准备")
        })
        let isReady = players.first { $0.playerID == selfID }?.ready ?? false
        readyButton.isEnabled = !isReady
        readyButton.configuration?.title = isReady ? "已准备" : "准备"
    }

    // Out of the room but still connected; the server follows up with its room list.
    func showRemoved(_ reason: String) {
        readyCountdown = nil
        setStage(.rooms)
        showStatus(reason)
    }

    // Back to the server list, e.g. after the connection drops.
    func showDisconnected(_ reason: String) {
        readyCountdown = nil
        setStage(.servers)
        showStatus(reason)
    }

    private func setStage(_ stage: Stage) {
        self.stage = stage
        if stage != .servers { autoConnect = false }
        let visible = stageViews[stage] ?? []
        for views in stageViews.values {
            views.forEach { $0.isHidden = !visible.contains($0) }
        }
        isModalInPresentation = stage == .room
        view.endEditing(true)
    }

    private func show(servers: [LANServer]) {
        self.servers = servers
        if let selected, !servers.contains(selected) { self.selected = nil }
        if selected == nil { selected = servers.first }
        serverStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, server) in servers.enumerated() {
            let button = UIButton(type: .system)
            var config = server == selected ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
            config.title = server.name
            config.subtitle = server.urls.first?.host
            config.baseBackgroundColor = UIColor(hex: 0x73B6A0)
            config.baseForegroundColor = server == selected ? .white : UIColor(hex: 0x365B4D)
            config.cornerStyle = .large
            button.configuration = config
            button.tag = index
            button.accessibilityIdentifier = "server_\(server.name)"
            button.addTarget(self, action: #selector(selectServer(_:)), for: .touchUpInside)
            serverStack.addArrangedSubview(button)
        }
        guard stage == .servers else { return }
        if statusLabel.text?.hasPrefix("正在搜索") == true || statusLabel.text?.hasPrefix("没有发现") == true {
            showStatus(servers.isEmpty ? Self.noServerHint : "点一个服务器连接")
        }
        connectAutomatically()
    }

    // The first time a server turns up (or one was given), connect without a
    // tap, so the room list is usually the first thing the player sees. After
    // that, picking a server is up to them.
    private func connectAutomatically() {
        guard autoConnect, stage == .servers, !addressField.isFirstResponder,
              selected != nil || addressField.text?.isEmpty == false else { return }
        connect()
    }

    @objc private func selectServer(_ sender: UIButton) {
        let server = servers[sender.tag]
        selected = server
        show(servers: servers)
        connect(to: server)
    }

    // The typed address if there is one, otherwise the selected server.
    @objc private func connect() {
        if let typed = addressField.text?.trimmingCharacters(in: .whitespaces), !typed.isEmpty {
            guard let manual = Self.server(fromAddress: typed) else { showStatus("地址格式不对，例如 192.168.1.10:7788"); return }
            connect(to: manual)
        } else if let selected {
            connect(to: selected)
        } else {
            showStatus(Self.noServerHint)
        }
    }

    private func connect(to server: LANServer) {
        autoConnect = false
        showStatus("正在连接 \(server.name)…")
        view.endEditing(true)
        onConnect?(server)
    }

    static func server(fromAddress text: String) -> LANServer? {
        let raw = text.contains("://") ? text : "ws://\(text)"
        guard var components = URLComponents(string: raw), components.host?.isEmpty == false else { return nil }
        if components.port == nil { components.port = 7788 }
        if components.path.isEmpty { components.path = "/ws" }
        guard let url = components.url else { return nil }
        return LANServer(name: components.host ?? text, urls: [url])
    }

    // The nickname to enter a room with, remembered for next time.
    private func playerName() -> String? {
        let name = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { showStatus("请先填写昵称"); return nil }
        UserDefaults.standard.set(name, forKey: "onlineName")
        return name
    }

    @objc private func create() {
        guard let name = playerName() else { return }
        view.endEditing(true)
        onCreate?(name, passwordField.text?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    @objc private func pickRoom(_ sender: UIButton) {
        guard let room = rooms.first(where: { $0.roomID == sender.tag }), let name = playerName() else { return }
        view.endEditing(true)
        guard room.locked else { onJoin?(room.roomID, name, ""); return }
        let alert = UIAlertController(title: "\(room.host) 的房间", message: "这个房间需要密码", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "房间密码"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "roomPasswordEntry"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "加入", style: .default) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.onJoin?(room.roomID, name, password)
        })
        present(alert, animated: true)
    }

    @objc private func ready() { onReady?() }

    @objc private func leave() {
        readyCountdown = nil
        showRooms(rooms) // the last list we saw; the server sends a fresh one
        onLeave?()
    }

    @objc private func switchServer() {
        onSwitchServer?()
        setStage(.servers)
        showStatus(servers.isEmpty ? Self.noServerHint : "点一个服务器连接")
    }

    @objc private func close() { onClose?() }

    private func configureField(_ field: UITextField, placeholder: String, identifier: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = identifier
    }

    private func configureButton(_ button: UIButton, title: String, identifier: String, action: Selector) {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseForegroundColor = UIColor(hex: 0x365B4D)
        config.baseBackgroundColor = UIColor(hex: 0x73B6A0)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        button.configuration = config
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }
}
