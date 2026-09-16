import UIKit
import GameKit

@MainActor
@objc(PBRTradingController)
final class RevivalTradingController: UITableViewController {
    private var authentication: FirebaseRESTAuthentication?
    private var api: TradingClient?
    private var ledger: RevivalInventoryLedger?
    private var room: TradeRoom?
    private var inventory: TradeInventory?
    private var selected = Set<String>()
    private var coins = 0
    private var queued = false
    private var busy = false
    private var healthy = false
    private var message = "Connecting…"
    private var timer: Timer?
    private var renewed = Date.distantPast
    private var gameID: String?
    private var labels: [String:String] = [:]
    private var lastRoom: String? {
        get { UserDefaults.standard.string(forKey: "RevivalActiveRoom") }
        set { UserDefaults.standard.set(newValue, forKey: "RevivalActiveRoom") }
    }

    @objc static func open(from presenter: UIViewController) {
        let controller = RevivalTradingController(style: .insetGrouped)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Revival Trading"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(closeTrading))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Refresh", style: .plain, target: self, action: #selector(refreshTrading))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        run { try await self.connect() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.api != nil, !self.busy,
                      UIApplication.shared.applicationState == .active else { return }
                self.run { try await self.refresh() }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.presentingViewController == nil { timer?.invalidate(); timer = nil }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; tableView.reloadData()
        Task { @MainActor in
            do { try await work() }
            catch { healthy = false; message = describe(error) }
            busy = false; tableView.reloadData()
        }
    }
    private func describe(_ error: Error) -> String {
        if case TradingClientError.server(_, let code) = error {
            if code == "VERIFIED_GOOGLE_ACCOUNT_REQUIRED" { return "The Render server needs its latest update. In Render, choose Manual Deploy → Deploy latest commit." }
            return "Trading server: \(code). Tap Refresh to check the result before trying again."
        }
        if case FirebaseAuthenticationError.rejected(let status) = error {
            return "Firebase rejected Game Center login (HTTP \(status)). Check the provider and the signed app's Game Center configuration."
        }
        return error.localizedDescription
    }
    private func connect() async throws {
        guard let url = Bundle.main.url(forResource: "RevivalFirebase", withExtension: "plist") else {
            throw RevivalFailure("Firebase configuration is missing from this build.")
        }
        let config = try FirebaseProjectConfiguration.load(plist: Data(contentsOf: url))
        let auth = try FirebaseRESTAuthentication(apiKey: config.apiKey)
        let player = GKLocalPlayer.local
        guard player.isAuthenticated else { throw RevivalFailure("Sign in to Game Center in the game, then tap Refresh.") }
        let team = player.teamPlayerID, game = player.gamePlayerID
        let proof: GameCenterCredential = try await withCheckedThrowingContinuation { continuation in
            player.fetchItems { url, signature, salt, timestamp, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let url = url, let signature = signature, let salt = salt else {
                    continuation.resume(throwing: RevivalFailure("Game Center did not return an identity proof.")); return
                }
                continuation.resume(returning: GameCenterCredential(teamPlayerID: team, gamePlayerID: game,
                    publicKeyURL: url, signature: signature, salt: salt, timestamp: timestamp, displayName: player.displayName))
            }
        }
        guard player.isAuthenticated, player.gamePlayerID == game else { throw FirebaseAuthenticationError.sessionChanged }
        let session = try await auth.signIn(gameCenter: proof, bundleID: Bundle.main.bundleIdentifier ?? "")
        authentication = auth; gameID = game
        message = "Game Center and Firebase connected. Waking trading server…"; tableView.reloadData()
        // Only the read-only health check is retried while Render wakes from sleep.
        let transport = URLSessionTradingTransport()
        var awake = false
        for _ in 0..<3 {
            do {
                let (_, response) = try await transport.send(URLRequest(url: URL(string: "https://pacybits-revival-trading.onrender.com/healthz")!))
                if response.statusCode == 200 { awake = true; break }
            } catch {}
        }
        guard awake else { throw RevivalFailure("Trading server is still waking up. Tap Refresh in a minute.") }
        let client = try TradingClient(endpoint: URL(string: "https://pacybits-revival-trading.onrender.com/trading")!) { try await auth.session() }
        let registered = try await client.register()
        let storage = try RevivalInventoryLedger(uid: session.uid)
        if registered.inventoryReady == false {
            let local = try storage.prepareImport(uid: session.uid)
            _ = try await client.importLegacyInventory(local, preserveFirstCopy: true)
        }
        guard storage.record != nil else { throw RevivalFailure("This account already has a collection on another installation. No local save was replaced.") }
        ledger = storage; api = client
        try await refresh()
    }
    private func label(_ id: String) -> String {
        if let value = labels[id] { return value }
        let value = PBRCardLabel(id) ?? "Card \(id)"
        labels[id] = value
        return value
    }
    private func checkOffer(_ offer: TradeOffer) throws {
        guard let local = try ledger?.bridge.snapshot(), local.coins >= offer.coins,
              offer.cards.allSatisfy({ (local.cards[$0] ?? 0) > 1 }) else {
            throw RevivalFailure("You no longer have these coins or duplicates in the game. Change your offer.")
        }
    }
    private func checkPlayer() throws {
        guard GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == gameID else {
            throw RevivalFailure("Game Center account changed. Close Trading and sign in again.")
        }
    }
    private func refresh() async throws {
        try checkPlayer()
        guard let client = api, let storage = ledger else { return }
        if queued && Date().timeIntervalSince(renewed) >= 20 {
            accept(try await client.enterOrRenewQueue()); renewed = Date()
        }
        let result = try await client.status(roomID: lastRoom)
        try storage.reconcile(result)
        healthy = true
        inventory = result.inventory
        accept(result)
        if room?.isCompleted == true {
            message = "Trade completed and saved to your collection."
            lastRoom = nil; room = nil; selected = []; coins = 0
        } else if let room = room, room.status != "open" {
            message = "Trade \(room.status)."; self.room = nil; lastRoom = nil; selected = []; coins = 0
        } else if let room = room {
            let ready = room.members.filter { room.ready[$0] == room.revision }.count
            message = room.members.count == 1 ? "Waiting for your friend. Share your invite." : "Connected • \(ready)/2 players ready"
        } else {
            message = queued ? "Searching for a trading partner…" : "Connected as \(GKLocalPlayer.local.displayName). Select up to three duplicates to offer."
        }
    }
    private func accept(_ response: TradingResponse) {
        if let value = response.queued { queued = value }
        if let value = response.room {
            let changed = room?.id != value.id || room?.revision != value.revision
            room = value; lastRoom = value.id; queued = false
            if changed, let offer = value.offers[value.selfKey] { selected = Set(offer.cards); coins = offer.coins }
        }
    }
    @objc private func refreshTrading() {
        run { if self.api == nil { try await self.connect() } else { try await self.refresh() } }
    }
    @objc private func closeTrading() {
        run {
            if let client = self.api {
                try self.checkPlayer()
                if let id = self.lastRoom { self.accept(try await client.cancel(roomID: id)) }
                if self.queued { _ = try await client.leaveQueue(); self.queued = false }
                try await self.refresh()
            }
            self.timer?.invalidate(); self.timer = nil
            self.dismiss(animated: true)
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return api == nil ? 1 : room == nil ? 3 : 5 }
        if section == 2 { return room?.members.count ?? 0 }
        return availableCards.count
    }
    private var availableCards: [String] {
        (inventory?.cards ?? [:]).filter { $0.value > 1 }.keys.sorted()
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 2 { return "Offers" }
        if section == 3 { return "Tradeable cards • \(inventory?.coins ?? 0) coins" }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if path.section == 0 { cell.textLabel?.text = message; cell.detailTextLabel?.text = busy ? "Please wait…" : nil }
        if path.section == 1 {
            let actions = api == nil ? ["Connect"] : room == nil ? ["Create invite", "Join invite", queued ? "Stop searching" : "Random trade"] : ["Copy invite", "Set coins", "Send offer", "Ready", "Confirm trade"]
            cell.textLabel?.text = actions[path.row]; cell.textLabel?.textColor = .systemBlue
        }
        if path.section == 2, let room = room {
            let member = room.members[path.row], offer = room.offers[member]
            cell.textLabel?.text = member == room.selfKey ? "You" : "Partner"
            cell.detailTextLabel?.text = "\(offer?.coins ?? 0) coins\n\((offer?.cards ?? []).map { label($0) }.joined(separator: ", "))"
        }
        if path.section == 3 {
            let id = availableCards[path.row]
            cell.textLabel?.text = label(id)
            cell.detailTextLabel?.text = "\((inventory?.cards[id] ?? 1) - 1) duplicates"
            cell.accessoryType = selected.contains(id) ? .checkmark : .none
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        guard !busy else { return }
        if path.section == 3 {
            let id = availableCards[path.row]
            if selected.contains(id) { selected.remove(id) } else if selected.count < 3 { selected.insert(id) }
            tableView.reloadData(); return
        }
        guard path.section == 1 else { return }
        guard let client = api else { refreshTrading(); return }
        guard healthy else { refreshTrading(); return }
        if let room = room {
            switch path.row {
            case 0: UIPasteboard.general.string = room.id; message = "Invite copied. Send it to your friend."; tableView.reloadData()
            case 1: prompt(title: "Coins to offer", numeric: true) { value in
                guard let amount = Int(value), amount >= 0, amount <= (self.inventory?.coins ?? 0) else { return }
                self.coins = amount; self.message = "Offer: \(amount) coins. Tap Send offer to update it."; self.tableView.reloadData()
            }
            case 2: run { try self.checkPlayer(); try self.checkOffer(TradeOffer(coins: self.coins, cards: Array(self.selected))); self.accept(try await client.updateOffer(room: room, offer: TradeOffer(coins: self.coins, cards: Array(self.selected)))); try await self.refresh() }
            case 3: run { try self.checkPlayer(); self.accept(try await client.ready(room: room)); try await self.refresh() }
            default:
                let alert = UIAlertController(title: "Confirm this trade?", message: "Your offer: \(room.offers[room.selfKey]?.coins ?? 0) coins and \(room.offers[room.selfKey]?.cards.joined(separator: ", ") ?? "no cards"). Both players must confirm the same offers.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in self.run {
                    try self.checkPlayer(); if let offer = room.offers[room.selfKey] { try self.checkOffer(offer) }; self.accept(try await client.confirm(room: room)); try await self.refresh()
                } })
                present(alert, animated: true)
            }
        } else {
            switch path.row {
            case 0: run { try self.checkPlayer(); self.accept(try await client.createInvitation()); try await self.refresh() }
            case 1: prompt(title: "Paste your friend's invite") { id in self.run {
                try self.checkPlayer(); self.accept(try await client.joinInvitation(roomID: id.trimmingCharacters(in: .whitespacesAndNewlines))); try await self.refresh()
            } }
            default: run {
                try self.checkPlayer()
                if self.queued { _ = try await client.leaveQueue(); self.queued = false }
                else { self.accept(try await client.enterOrRenewQueue()); self.renewed = Date() }
                try await self.refresh()
            }
            }
        }
    }
    private func prompt(title: String, numeric: Bool = false, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { if numeric { $0.keyboardType = .numberPad } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in completion(alert.textFields?.first?.text ?? "") })
        present(alert, animated: true)
    }
}
