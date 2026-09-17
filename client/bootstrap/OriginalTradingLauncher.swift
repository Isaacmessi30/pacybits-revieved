import UIKit

@MainActor
@objc(PBROriginalTradingLauncher)
final class OriginalTradingLauncher: NSObject {
    @objc static func open(from presenter: UIViewController, mode: String) {
        let selected: OriginalTradingCoordinator.Mode
        switch mode.lowercased() {
        case "code": selected = .code
        case "friends": selected = .friends
        case "channels": selected = .channels
        default: selected = .random
        }
        OriginalTradingCoordinator.open(from: presenter, mode: selected)
    }
}
