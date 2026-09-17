import UIKit

/// Owns the replacement transport while PACYBITS keeps ownership of the actual
/// Trading.storyboard, controls, animations and local interaction state.
@MainActor
final class OriginalTradingCoordinator {
    enum Mode { case random, code, friends, channels }

    private static var active: OriginalTradingCoordinator?

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
    private var closed = false
    private var firebaseUID: String?
    private var waitingAlert: UIAlertController?

    static func open(from presenter: UIViewController, mode: Mode) {
        guard active == nil else { return }
        let coordinator = OriginalTradingCoordinator()
        active = coordinator
        coordinator.presenter = presenter
        coordinator.matchmakingTask = Task { @MainActor in
            do { try await coordinator.start(mode: mode) }
            catch is CancellationError { coordinator.cleanup(cancelServer: true) }
            catch { coordinator.fail(error) }
        }
    }

    private func start(mode: Mode) async throws {
        let (client, storage) = try await connect()
        api = client
        ledger = storage
        switch mode {
        case .random, .channels:
            try await randomMatch(client)
        case .code, .friends:
            try await chooseInvitation(client)
        }
    }

    private func connect() async throws -> (TradingClient, RevivalInventoryLedger) {
        guard let presenter,
              let url = Bundle.main.url(forResource: "RevivalFirebase", withExtension: "plist") else {
            throw RevivalFailure("Firebase configuration is missing from this build.")
        }
        let config = try FirebaseProjectConfiguration.load(plist: Data(contentsOf: url))
        let auth = try FirebaseRESTAuthentication(
            apiKey: config.apiKey,
            store: KeychainFirebaseSessionStore(projectID: config.projectID, bundleID: config.bundleID))
        authentication = auth
        let credentials: FirebaseSession
        do { credentials = try await auth.session() }
        catch FirebaseAuthenticationError.signInRequired {
            credentials = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                .signIn(presenting: presenter)
        }
        firebaseUID = credentials.uid

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

        let client = try TradingClient(
            endpoint: URL(string: "https://pacybits-revival-trading.onrender.com/trading")!) {
                try await auth.session()
            }
        let registered = try await client.register()
        let storage = try RevivalInventoryLedger(uid: credentials.uid)
        if registered.inventoryReady == false {
            let local = try storage.prepareImport(uid: credentials.uid)
            _ = try await client.importLegacyInventory(local, preserveFirstCopy: true)
        }
        guard storage.record != nil else {
            throw RevivalFailure("This account already has a collection on another installation.")
        }
        return (client, storage)
    }

    private func checkPlayer() async throws {
        guard let authentication, let firebaseUID,
              try await authentication.session().uid == firebaseUID else {
            throw RevivalFailure("Google account changed. Reopen Trading and sign in again.")
        }
    }

    private func randomMatch(_ client: TradingClient) async throws {
        showWaiting(title: "Trading", message: "Searching for a trading partner…")
        var response = try await client.enterOrRenewQueue()
        var renewed = Date()
        while !Task.isCancelled {
            if let room = response.room, room.members.count == 2 {
                dismissWaiting()
                try launch(response)
                return
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await checkPlayer()
            if Date().timeIntervalSince(renewed) >= 20 {
                response = try await client.enterOrRenewQueue()
                renewed = Date()
            } else {
                response = try await client.status(roomID: response.room?.id)
            }
        }
        throw CancellationError()
    }

    private func chooseInvitation(_ client: TradingClient) async throws {
        guard let presenter else { throw RevivalFailure("Trading screen is unavailable.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let alert = UIAlertController(title: "Trade by code", message: "Create an invite or enter a friend's invite.", preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Create invite", style: .default) { _ in
                Task { @MainActor in
                    do { try await self.createInvitation(client); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            })
            alert.addAction(UIAlertAction(title: "Enter invite", style: .default) { _ in
                self.promptForInvitation(client, continuation: continuation)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(throwing: CancellationError())
            })
            presenter.present(alert, animated: true)
        }
    }

    private func createInvitation(_ client: TradingClient) async throws {
        var response = try await client.createInvitation()
        guard let room = response.room else { throw TradingClientError.invalidResponse }
        UIPasteboard.general.string = room.id
        showWaiting(title: "Invite copied", message: "Send the copied invite to your friend. Waiting for them to join…")
        while !Task.isCancelled {
            if let current = response.room, current.members.count == 2 {
                dismissWaiting(); try launch(response); return
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            response = try await client.status(roomID: room.id)
        }
        throw CancellationError()
    }

    private func promptForInvitation(_ client: TradingClient,
                                     continuation: CheckedContinuation<Void, Error>) {
        guard let presenter else { continuation.resume(throwing: RevivalFailure("Trading screen is unavailable.")); return }
        let alert = UIAlertController(title: "Enter invite", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            continuation.resume(throwing: CancellationError())
        })
        alert.addAction(UIAlertAction(title: "Join", style: .default) { _ in
            let code = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                do {
                    let response = try await client.joinInvitation(roomID: code)
                    guard response.room?.members.count == 2 else { throw TradingClientError.invalidResponse }
                    try self.launch(response)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        })
        presenter.present(alert, animated: true)
    }

    private func validateOffer(_ offer: TradeOffer) throws {
        guard let local = try ledger?.bridge.snapshot(), local.coins >= offer.coins,
              offer.cards.allSatisfy({ (local.cards[$0] ?? 0) > 1 }) else {
            throw RevivalFailure("You no longer have the cards or coins in this offer.")
        }
    }

    private func launch(_ initial: TradingResponse) throws {
        guard let presenter, let client = api, let room = initial.room,
              room.members.count == 2 else { throw TradingClientError.invalidResponse }
        let tradeSession = try OriginalTradeSession(api: client, initial: initial) { [weak self] offer in
            guard let self else { throw TradingClientError.invalidResponse }
            try self.validateOffer(offer)
        }
        let native = try OriginalTradingScreen(peerClubName: "PACYBITS Player")
        session = tradeSession
        screen = native
        peerState = try OriginalTradePeerState(room: room)
        installOutboundBridge()
        native.controller.modalPresentationStyle = .fullScreen
        presenter.present(native.controller, animated: true)
        pollTask = Task { @MainActor [weak self] in await self?.pollLoop() }
    }

    private func installOutboundBridge() {
        LegacyOutboundBridge.handle = { [weak self] type, value in
            guard let self, !self.closed else { return false }
            // Always consume trading messages while the replacement session is live;
            // falling through would call the discontinued Game Center transport.
            if type == "tradingHandshake" {
                Task { @MainActor in await self.handleHandshake(value) }
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

    private func submit(_ action: OriginalTradeAction) async {
        guard let session, !closed else { return }
        do {
            try await checkPlayer()
            let response = try await session.submit(action)
            try process(response)
        } catch {
            showError(error)
            // An uncertain mutation is deliberately not replayed. A refresh gives
            // the session a new acknowledged revision before the next user action.
            do { try process(try await session.refresh()) } catch {}
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled && !closed {
            do {
                try await Task.sleep(nanoseconds: 1_250_000_000)
                guard let screen, screen.controller.presentingViewController != nil || screen.controller.view.window != nil else {
                    cleanup(cancelServer: true); return
                }
                guard let session else { return }
                try process(try await session.refresh())
            } catch is CancellationError { return }
            catch { showError(error) }
        }
    }

    private func process(_ response: TradingResponse) throws {
        guard let room = response.room else { throw TradingClientError.invalidResponse }
        if room.status == "cancelled" || room.status == "expired" {
            throw RevivalFailure("Your trading partner left the trade.")
        }
        let next = try OriginalTradePeerState(room: room)
        let events = try next.events(after: peerState)
        if !events.isEmpty { try screen?.render(events) }
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
            // Completion is authorized by the server receipt, not by the native packet.
            var receipt = completedReceipt
            if receipt == nil || receipt?.room?.isCompleted != true {
                receipt = try await session.refresh()
                if let receipt { try process(receipt) }
            }
            guard let receipt, receipt.room?.isCompleted == true else {
                throw RevivalFailure("Waiting for the server to confirm both players.")
            }
            localHandshakeSent = true
            let response = try await api?.nativeHandshake(roomID: roomID, payload: encoded)
            if let response { try process(response) }
        } catch { showError(error) }
    }

    private func finishWithPeerHandshake(_ encoded: String) throws {
        guard !nativeSettlementStarted, let receipt = completedReceipt,
              let ledger, let screen else { return }
        nativeSettlementStarted = true
        do {
            let shouldRunNative = try ledger.prepareNativeSettlement(receipt)
            guard shouldRunNative else { cleanup(cancelServer: false); return }
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
        // PACYBITS owns the visible completion/post-trade animation. We only drop
        // the replacement transport after its original save has been verified.
        pollTask?.cancel(); pollTask = nil
        LegacyOutboundBridge.handle = nil
        screen?.restoreProfile()
        session = nil
        completedReceipt = nil
    }

    private func showWaiting(title: String, message: String) {
        dismissWaiting()
        guard let presenter else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.matchmakingTask?.cancel()
            self.cleanup(cancelServer: true)
        })
        waitingAlert = alert
        presenter.present(alert, animated: true)
    }

    private func dismissWaiting() {
        if waitingAlert?.presentingViewController != nil { waitingAlert?.dismiss(animated: true) }
        waitingAlert = nil
    }

    private func showError(_ error: Error) {
        guard !closed else { return }
        let message: String
        if case TradingClientError.server(_, let code) = error { message = "Trading server: \(code)" }
        else { message = error.localizedDescription }
        let owner = screen?.controller ?? presenter
        guard let owner, owner.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Trading", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        owner.present(alert, animated: true)
    }

    private func fail(_ error: Error) {
        dismissWaiting()
        showError(error)
        cleanup(cancelServer: false)
    }

    private func cleanup(cancelServer: Bool) {
        guard !closed else { return }
        closed = true
        matchmakingTask?.cancel(); matchmakingTask = nil
        pollTask?.cancel(); pollTask = nil
        dismissWaiting()
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
