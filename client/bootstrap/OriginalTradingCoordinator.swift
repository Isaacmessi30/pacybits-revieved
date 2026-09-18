import UIKit

/// Owns only the replacement transport. PACYBITS continues to own the original
/// menu, dialogs, search UI, Trading.storyboard, controls and animations.
@MainActor
final class OriginalTradingCoordinator {
    enum Mode { case random, code, friends, channels }
    private enum CollectionRelinkChoice { case useDevice, restoreServer, cancel }

    private static var active: OriginalTradingCoordinator?

    private static func probe(_ label: String) async {
        guard let url = URL(string: "https://pacybits-revival-trading.onrender.com/healthz") else { return }
        var request = URLRequest(url: url)
        request.setValue(label, forHTTPHeaderField: "X-Revival-Probe")
        _ = try? await URLSession.shared.data(for: request)
    }

    static var hasActiveMatch: Bool { active != nil }

    /// Authenticates before PACYBITS enters any trading mode. A cached Firebase
    /// refresh token is restored from Keychain, so Google UI appears only when
    /// there is no reusable session (or Firebase has revoked it).
    static func ensureAuthenticated(from presenter: UIViewController) async throws {
        guard let url = Bundle.main.url(forResource: "RevivalFirebase", withExtension: "plist") else {
            throw RevivalFailure("Firebase configuration is missing from this build.")
        }
        let config = try FirebaseProjectConfiguration.load(plist: Data(contentsOf: url))
        let auth = try FirebaseRESTAuthentication(
            apiKey: config.apiKey,
            store: KeychainFirebaseSessionStore(projectID: config.projectID, bundleID: config.bundleID))
        do {
            _ = try await auth.session()
        } catch FirebaseAuthenticationError.signInRequired {
            _ = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                .signIn(presenting: presenter)
        } catch FirebaseAuthenticationError.rejected(let status) where [400, 401, 403].contains(status) {
            _ = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                .signIn(presenting: presenter)
        }
    }

    private weak var presenter: UIViewController?
    private var authentication: FirebaseRESTAuthentication?
    private var api: TradingClient?
    private var ledger: RevivalInventoryLedger?
    private var session: OriginalTradeSession?
    private var screen: OriginalTradingScreen?
    private var peerState: OriginalTradePeerState?
    private var completedReceipt: TradingResponse?
    private var pollTask: Task<Void, Never>?
    private var matchmakingTask: Task<Void, Never>?
    private var localHandshakeSent = false
    private var nativeSettlementStarted = false
    private var nativeScreenMisses = 0
    private var lastPeerSignalSeq = 0
    private var closed = false
    private var firebaseUID: String?

    /// Retained for compatibility with older test bootstraps. New builds enter
    /// through beginOriginalMatch after PACYBITS creates its own GKMatchRequest.
    static func open(from presenter: UIViewController, mode: Mode) {
        let scope: String
        switch mode {
        case .random: scope = "g:0:a:0"
        case .code: scope = "legacy:code"
        case .friends: scope = "legacy:friends"
        case .channels: scope = "legacy:channels"
        }
        beginOriginalMatch(from: presenter, scope: scope, targetLegacyID: nil, localLegacyID: nil)
    }

    static func beginOriginalMatch(from presenter: UIViewController,
                                   scope: String,
                                   targetLegacyID: String?,
                                   localLegacyID: String?) {
        guard active == nil else { return }
        let normalized = String(scope.prefix(128))
        guard !normalized.isEmpty else { return }
        let coordinator = OriginalTradingCoordinator()
        active = coordinator
        coordinator.presenter = presenter
        coordinator.matchmakingTask = Task { @MainActor in
            do {
                try await coordinator.startOriginal(
                    scope: normalized,
                    targetLegacyID: targetLegacyID,
                    localLegacyID: localLegacyID)
            } catch is CancellationError {
                coordinator.cleanup(cancelServer: true)
            } catch {
                coordinator.fail(error)
            }
        }
    }

    static func cancelActiveMatch() {
        active?.cleanup(cancelServer: true)
    }

    private func startOriginal(scope: String,
                               targetLegacyID: String?,
                               localLegacyID: String?) async throws {
        let (client, storage) = try await connect(legacyID: localLegacyID)
        api = client
        ledger = storage
        try await scopedMatch(client, scope: scope, targetLegacyID: targetLegacyID)
    }

    private func connect(legacyID: String?) async throws -> (TradingClient, RevivalInventoryLedger) {
        guard let presenter,
              let url = Bundle.main.url(forResource: "RevivalFirebase", withExtension: "plist") else {
            throw RevivalFailure("Firebase configuration is missing from this build.")
        }
        let config = try FirebaseProjectConfiguration.load(plist: Data(contentsOf: url))
        let auth = try FirebaseRESTAuthentication(
            apiKey: config.apiKey,
            store: KeychainFirebaseSessionStore(projectID: config.projectID, bundleID: config.bundleID))
        authentication = auth

        // Prove backend reachability before Firebase session restoration. A stale
        // cached token must never make Random fail before the first network probe.
        let transport = URLSessionTradingTransport()
        var awake = false
        for _ in 0..<4 {
            try Task.checkCancellation()
            do {
                let (_, response) = try await transport.send(URLRequest(
                    url: URL(string: "https://pacybits-revival-trading.onrender.com/healthz")!))
                if response.statusCode == 200 { awake = true; break }
            } catch {}
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard awake else { throw RevivalFailure("Trading server is unavailable.") }
        await Self.probe("auth-start")

        let credentials: FirebaseSession
        do {
            credentials = try await auth.session()
            await Self.probe("auth-session-ok")
        } catch FirebaseAuthenticationError.signInRequired {
            await Self.probe("auth-login-start")
            credentials = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                .signIn(presenting: presenter)
            await Self.probe("auth-login-ok")
        } catch FirebaseAuthenticationError.rejected(let status) where [400, 401, 403].contains(status) {
            await Self.probe("auth-login-start")
            credentials = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                .signIn(presenting: presenter)
            await Self.probe("auth-login-ok")
        } catch {
            await Self.probe("auth-session-error")
            throw error
        }
        firebaseUID = credentials.uid

        let client = try TradingClient(
            endpoint: URL(string: "https://pacybits-revival-trading.onrender.com/trading")!) {
                try await auth.session()
            }
        await Self.probe("register-start")
        let registered = try await client.register(legacyID: legacyID)
        await Self.probe("register-ok")
        let storage = try RevivalInventoryLedger(uid: credentials.uid)
        if registered.inventoryReady == false {
            let local = try storage.prepareImport(uid: credentials.uid)
            _ = try await client.importLegacyInventory(local, preserveFirstCopy: true)
        } else if storage.record == nil {
            let status = try await client.status()
            guard let server = status.inventory, let version = status.inventoryVersion, version > 0 else {
                throw TradingClientError.invalidResponse
            }
            let local = try storage.localSnapshot()
            if local == server {
                try storage.attachServerBaseline(uid: credentials.uid, response: status)
            } else {
                switch try await chooseCollectionRelink(local: local, server: server) {
                case .useDevice:
                    let replaced = try await client.replaceInventory(
                        local, expectedVersion: version, preserveFirstCopy: true)
                    try storage.attachServerBaseline(uid: credentials.uid, response: replaced)
                case .restoreServer:
                    try storage.restoreServerCollection(uid: credentials.uid, response: status)
                case .cancel:
                    throw CancellationError()
                }
            }
        }
        guard storage.record != nil else {
            throw RevivalFailure("The trading collection could not be attached to this installation.")
        }
        return (client, storage)
    }

    private func chooseCollectionRelink(local: TradeInventory,
                                        server: TradeInventory) async throws -> CollectionRelinkChoice {
        guard let presenter else { throw CancellationError() }
        return await withCheckedContinuation { continuation in
            let localSummary = "\(local.coins) coins, \(local.cards.values.reduce(0, +)) cards"
            let serverSummary = "\(server.coins) coins, \(server.cards.values.reduce(0, +)) cards"
            let alert = UIAlertController(
                title: "Trading collection",
                message: "This device and your saved trading account contain different collections.\n\nThis device: \(localSummary)\nSaved online: \(serverSummary)",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Use This Device", style: .default) { _ in
                continuation.resume(returning: .useDevice)
            })
            alert.addAction(UIAlertAction(title: "Restore Saved Online", style: .default) { _ in
                continuation.resume(returning: .restoreServer)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: .cancel)
            })
            presenter.present(alert, animated: true)
        }
    }

    private func checkPlayer() async throws {
        guard let authentication, let firebaseUID,
              try await authentication.session().uid == firebaseUID else {
            throw RevivalFailure("Google account changed. Reopen Trading and sign in again.")
        }
    }

    private func scopedMatch(_ client: TradingClient,
                             scope: String,
                             targetLegacyID: String?) async throws {
        var response = try await client.enterOrRenewQueue(scope: scope, targetLegacyID: targetLegacyID)
        var renewed = Date()
        while !Task.isCancelled {
            if let room = response.room, room.members.count == 2 {
                try launch(response)
                return
            }
            try await Task.sleep(nanoseconds: 1_250_000_000)
            try await checkPlayer()
            if Date().timeIntervalSince(renewed) >= 20 {
                response = try await client.enterOrRenewQueue(scope: scope, targetLegacyID: targetLegacyID)
                renewed = Date()
            } else {
                response = try await client.status(roomID: response.room?.id)
            }
        }
        throw CancellationError()
    }

    private func validateOffer(_ offer: TradeOffer) throws {
        guard let local = try ledger?.bridge.snapshot(), local.coins >= offer.coins,
              offer.cards.allSatisfy({ (local.cards[$0] ?? 0) > 1 }) else {
            throw RevivalFailure("You no longer have the cards or coins in this offer.")
        }
    }

    private func launch(_ initial: TradingResponse) throws {
        guard let client = api, let room = initial.room,
              room.members.count == 2 else { throw TradingClientError.invalidResponse }
        let tradeSession = try OriginalTradeSession(api: client, initial: initial) { [weak self] offer in
            guard let self else { throw TradingClientError.invalidResponse }
            try self.validateOffer(offer)
        }
        session = tradeSession
        peerState = try OriginalTradePeerState(room: room)
        installOutboundBridge()

        guard PBRStartOriginalNativeMatch("PACYBITS Player") else {
            throw RevivalFailure("PACYBITS could not start its original match-found transition.")
        }

        try process(initial)
        try attachNativeScreenIfReady()
        pollTask = Task { @MainActor [weak self] in await self?.pollLoop() }
    }

    private func installOutboundBridge() {
        LegacyOutboundBridge.handle = { [weak self] type, value in
            guard let self, !self.closed else { return false }
            if type == "tradingHandshake" {
                Task { @MainActor in await self.handleHandshake(value) }
                return true
            }
            if Self.presentationSignalTypes.contains(type) {
                Task { @MainActor in await self.submitSignal(type: type, value: value) }
                return true
            }
            do {
                let action = try OriginalTradeProtocol.decode(type: type, value: value) { object in
                    PBRPlayerIdentifier(object as AnyObject)
                }
                Task { @MainActor in await self.submit(action) }
            } catch {
                Task { @MainActor in self.showError(error) }
            }
            return true
        }
    }

    private static let pretradeSignalTypes: Set<String> = [
        "new_friend_info", "tradingIntro"
    ]

    private static let presentationSignalTypes: Set<String> = [
        "new_friend_info", "tradingIntro",
        "tradingDidSetMessage", "tradingDidSetFilters", "tradingDidSetWishlist",
        "emote",
        "tradingStartAnimatingOutline", "tradingStopAnimatingOutline",
        "tradingStartAnimatingWishlist", "tradingStopAnimatingWishlist",
        "tradingThumbsOutline"
    ]

    private func submitSignal(type: String, value: Any?) async {
        guard let api, let roomID = peerState?.roomID, !closed else { return }
        do {
            let box: [String:Any] = value == nil ? ["nil": true] : ["value": value!]
            guard PropertyListSerialization.propertyList(box, isValidFor: .binary) else {
                throw RevivalFailure("PACYBITS could not encode this trading UI event.")
            }
            let data = try PropertyListSerialization.data(fromPropertyList: box, format: .binary, options: 0)
            guard data.count <= 8_192 else { throw RevivalFailure("Trading UI event is too large.") }
            let response = try await api.sendSignal(roomID: roomID, type: type, payload: data.base64EncodedString())
            try process(response)
        } catch {
            showError(error)
        }
    }

    private func submit(_ action: OriginalTradeAction) async {
        guard let session, !closed else { return }
        do {
            try await checkPlayer()
            let response = try await session.submit(action)
            try process(response)
        } catch {
            showError(error)
            do { try process(try await session.refresh()) } catch {}
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled && !closed {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                if let screen,
                   screen.controller.presentingViewController == nil &&
                   screen.controller.navigationController == nil &&
                   screen.controller.view.window == nil {
                    cleanup(cancelServer: true)
                    return
                }
                guard let session else { return }
                try process(try await session.refresh())
                try attachNativeScreenIfReady()
            } catch is CancellationError { return }
            catch { showError(error) }
        }
    }

    private func attachNativeScreenIfReady() throws {
        guard screen == nil else { return }

        if let native = try OriginalTradingScreen.attachCurrent(peerClubName: "PACYBITS Player") {
            screen = native
            nativeScreenMisses = 0
            return
        }

        nativeScreenMisses += 1
        guard nativeScreenMisses >= 2,
              let controller = PBRPresentOriginalTradingFallback() else {
            return
        }

        screen = try OriginalTradingScreen(
            peerClubName: "PACYBITS Player",
            existingController: controller,
            updateProfile: true)
        nativeScreenMisses = 0
    }

    private func process(_ response: TradingResponse) throws {
        guard let room = response.room else { throw TradingClientError.invalidResponse }
        if room.status == "cancelled" || room.status == "expired" {
            throw RevivalFailure("Your trading partner left the trade.")
        }
        let next = try OriginalTradePeerState(room: room)
        let events = try next.events(after: peerState)
        if !events.isEmpty { try screen?.render(events) }

        for signal in room.peerSignals.sorted(by: { $0.seq < $1.seq })
        where signal.seq > lastPeerSignalSeq {
            if let screen {
                try screen.renderSignal(signal)
                lastPeerSignalSeq = max(lastPeerSignalSeq, signal.seq)
            } else if Self.pretradeSignalTypes.contains(signal.type) {
                try OriginalTradingScreen.deliverPretradeSignal(signal)
                lastPeerSignalSeq = max(lastPeerSignalSeq, signal.seq)
                try attachNativeScreenIfReady()
            } else {
                break
            }
        }
        peerState = next
        if room.isCompleted {
            guard response.inventory != nil, (response.inventoryVersion ?? 0) > 0 else {
                throw TradingClientError.invalidResponse
            }
            completedReceipt = response
            if let encoded = room.peerHandshake { try finishWithPeerHandshake(encoded) }
        }
    }

    private func handleHandshake(_ value: Any?) async {
        guard !localHandshakeSent, let session, let roomID = peerState?.roomID else { return }
        do {
            let encoded = try encodeHandshake(value)
            var receipt = completedReceipt
            if receipt == nil || receipt?.room?.isCompleted != true {
                receipt = try await session.refresh()
                if let receipt { try process(receipt) }
            }
            guard let receipt, let room = receipt.room, room.isCompleted else {
                throw RevivalFailure("Waiting for the server to confirm both players.")
            }
            if room.handshakes?[room.selfKey] == encoded {
                localHandshakeSent = true
                try process(receipt)
                return
            }
            guard let api else { throw TradingClientError.invalidResponse }
            do {
                let response = try await api.nativeHandshake(roomID: roomID, payload: encoded)
                localHandshakeSent = true
                try process(response)
            } catch {
                let refreshed = try await session.refresh()
                if let current = refreshed.room,
                   current.handshakes?[current.selfKey] == encoded {
                    localHandshakeSent = true
                    try process(refreshed)
                    return
                }
                throw error
            }
        } catch { showError(error) }
    }

    private func finishWithPeerHandshake(_ encoded: String) throws {
        guard !nativeSettlementStarted, let receipt = completedReceipt,
              let ledger, let screen else { return }
        nativeSettlementStarted = true
        do {
            let shouldRunNative = try ledger.prepareNativeSettlement(receipt)
            guard shouldRunNative else { finishSuccessfully(); return }
            let value = try decodeHandshake(encoded)
            try screen.renderHandshake(value)
            Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<12 {
                    do {
                        try ledger.finishNativeSettlement()
                        self.finishSuccessfully()
                        return
                    } catch {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                self.nativeSettlementStarted = false
                self.showError(RevivalFailure("The confirmed trade could not be verified in the original save."))
            }
        } catch {
            nativeSettlementStarted = false
            throw error
        }
    }

    private func encodeHandshake(_ value: Any?) throws -> String {
        guard let dictionary = value as? [String:Any],
              Set(dictionary.keys) == Set(["coins", "idsLeft", "idsRight"]),
              PropertyListSerialization.propertyList(dictionary, isValidFor: .binary) else {
            throw RevivalFailure("The original completion packet is invalid.")
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        guard data.count <= 8_192 else { throw RevivalFailure("The original completion packet is too large.") }
        return data.base64EncodedString()
    }

    private func decodeHandshake(_ encoded: String) throws -> [String:Any] {
        guard encoded.count <= 12_000, let data = Data(base64Encoded: encoded), data.count <= 8_192,
              let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String:Any],
              Set(dictionary.keys) == Set(["coins", "idsLeft", "idsRight"]) else {
            throw RevivalFailure("The partner completion packet is invalid.")
        }
        return dictionary
    }

    private func finishSuccessfully() {
        pollTask?.cancel(); pollTask = nil
        LegacyOutboundBridge.handle = nil
        screen?.restoreProfile()
        session = nil
        completedReceipt = nil
        closed = true
        OriginalTradingCoordinator.active = nil
    }

    private func showError(_ error: Error) {
        guard !closed else { return }
        let message: String
        if case TradingClientError.server(_, let code) = error { message = "Trading server: \(code)" }
        else { message = error.localizedDescription }
        var owner = screen?.controller ?? presenter
        while let presented = owner?.presentedViewController {
            owner = presented
        }
        guard let owner else { return }
        let alert = UIAlertController(title: "Trading", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        owner.present(alert, animated: true)
    }

    private func fail(_ error: Error) {
        showError(error)
        cleanup(cancelServer: false)
    }

    private func cleanup(cancelServer: Bool) {
        guard !closed else { return }
        closed = true
        matchmakingTask?.cancel(); matchmakingTask = nil
        pollTask?.cancel(); pollTask = nil
        LegacyOutboundBridge.handle = nil
        screen?.restoreProfile()
        if cancelServer, let api {
            let roomID = peerState?.roomID
            Task {
                if let roomID { _ = try? await api.cancel(roomID: roomID) }
                else { _ = try? await api.leaveQueue() }
            }
        }
        session = nil; screen = nil; peerState = nil; completedReceipt = nil
        OriginalTradingCoordinator.active = nil
    }
}
