import AppKit
import OSLog
import Sparkle

/// Sparkle owns scheduling, verification and installation; our driver owns presentation.
/// An unconfigured development executable never starts network update checks.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "updates")
    private var updater: SPUUpdater?
    private let driver = UpdateUserDriver()
    private(set) var hasAvailableUpdate = false
    var onAvailabilityChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        driver.onAvailabilityChanged = { [weak self] available in
            self?.setAvailable(available)
        }
    }

    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    func start() {
        guard updater == nil else { return }
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
        let created = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: driver, delegate: self)
        do {
            try created.start()
            updater = created
            // Only at startup: reuse Sparkle's single session and scheduler.
            // Its stored preferences remain authoritative; never override them on launch.
            if created.automaticallyChecksForUpdates,
               created.lastUpdateCheckDate.map({ Date().timeIntervalSince($0) >= max(3600, created.updateCheckInterval) }) ?? true {
                created.checkForUpdatesInBackground()
            }
        } catch {
            logger.error("Unable to start the updater: \(error.localizedDescription)")
        }
    }

    private func setAvailable(_ available: Bool) {
        guard hasAvailableUpdate != available else { return }
        hasAvailableUpdate = available
        onAvailabilityChanged?(available)
    }

    // Scheduled "no update" results may not be sent to the user driver.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { setAvailable(false) }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
    }
}
