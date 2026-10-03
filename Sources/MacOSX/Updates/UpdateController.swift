import AppKit
import OSLog
import Sparkle

/// Sparkle owns its scheduler, download verification and installation UI.
/// An unconfigured development executable never starts network update checks.
@MainActor
final class UpdateController: NSObject {
    private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "updates")
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["MacOSXUpdatesEnabled"] as? Bool == true else {
            logger.info("Updates are disabled in this build.")
            return
        }
        guard let key = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: key), decodedKey.count == 32,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
              info["SUAllowsAutomaticUpdates"] as? Bool == false else {
            logger.error("Invalid update configuration; updater will remain disabled.")
            return
        }
        let updater = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller = updater
        updater.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(sender)
    }
}
