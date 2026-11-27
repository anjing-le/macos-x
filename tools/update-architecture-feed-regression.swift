import AppKit
import Sparkle
import MacOSXCore

@main struct ArchitectureFeedRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let prefix = "https://github.com/anjing-le/macos-x/releases/latest/download/"
        for (architecture, filename, stale) in [("arm64", "appcast.xml", "appcast-intel.xml"), ("x86_64", "appcast-intel.xml", "appcast.xml")] {
            let identifier = "cc.anjing.macos-x.update-feed.fixture." + UUID().uuidString
            let app = root.appendingPathComponent(architecture + ".app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "FeedFixture", "CFBundleExecutable": "Fixture",
                                       "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.0.1",
                                       "SUFeedURL": prefix + filename]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            guard let bundle = Bundle(url: app), let defaults = UserDefaults(suiteName: identifier) else { fatalError("fixture bundle") }
            defer { defaults.removePersistentDomain(forName: identifier) }
            defaults.set(prefix + stale, forKey: "SUFeedURL")
            defaults.set(false, forKey: "SUEnableAutomaticChecks")
            defaults.set(false, forKey: "SUAutomaticallyUpdate")
            let driver = UpdateUserDriver()
            let controller = UpdateController(configuration: info)
            // Retrieve through the real Sparkle implementation; never call start,
            // checkForUpdates, or any user-driver presentation method.
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: controller)
            guard updater.feedURL?.absoluteString == prefix + filename else { fatalError("stale defaults crossed architecture feed") }
            guard defaults.string(forKey: "SUFeedURL") == prefix + stale,
                  defaults.bool(forKey: "SUEnableAutomaticChecks") == false,
                  defaults.bool(forKey: "SUAutomaticallyUpdate") == false,
                  !controller.canCheckForUpdates else { fatalError("routing mutated preferences or started updates") }
        }
        print("PASS real Sparkle: ARM/Intel signed configuration wins over stale opposite-architecture defaults; auto-check preferences preserved; no updater start, network, installed app, standard defaults or UI interaction")
    }
}
