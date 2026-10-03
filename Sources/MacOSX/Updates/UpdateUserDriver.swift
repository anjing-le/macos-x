import AppKit
import Sparkle

/// Presentation only. Sparkle owns downloads, validation, extraction and installation.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private enum Phase { case idle, checking, choosing, downloading, extracting, installing }
    private var phase: Phase = .idle
    private var panel: UpdatePanel?
    private var response: ((Bool) -> Void)?
    private var screen: UInt64 = 0
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private var targetVersion = ""

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        phase = .choosing
        prompt(title: "自动检查更新", detail: "安装前仍由你确认", primary: "允许", secondary: "手动检查") { allowed in
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: allowed,
                automaticUpdateDownloading: NSNumber(value: false), sendSystemProfile: false))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
        prompt(title: "检查更新", progress: .indeterminate, secondary: "取消") { _ in cancellation() }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .choosing
        targetVersion = String(appcastItem.displayVersionString.prefix(40))
        let versions = currentVersion.isEmpty ? targetVersion : "\(currentVersion) → \(targetVersion)"
        if appcastItem.isInformationOnlyUpdate {
            let url = appcastItem.infoURL
            let canOpen = url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil
            prompt(title: "更新说明", detail: targetVersion, primary: canOpen ? "查看" : nil, secondary: "关闭") { accepted in
                if accepted, canOpen, let url { NSWorkspace.shared.open(url) }
                reply(.dismiss)
            }
            return
        }
        let installing = state.stage == .installing
        prompt(title: appcastItem.isCriticalUpdate ? "重要更新" : "有新版本", detail: versions,
               primary: installing ? "安装并重启" : "更新", secondary: installing ? "取消" : "稍后") { accepted in
            reply(accepted ? .install : (installing ? .skip : .dismiss))
        }
    }

    // This app's feed deliberately has no linked release notes or web views.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .choosing
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        let title: String
        let detail: String?
        switch reason {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue:
            title = "已是最新版本"
            detail = currentVersion
        case SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            title = "无需更新"
            detail = currentVersion
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue:
            title = "需要更新 macOS"
            detail = "当前系统不支持此版本"
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue,
             SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            title = "暂无兼容更新"
            detail = "当前 Mac 不支持此版本"
        default:
            title = "未找到可用更新"
            detail = nsError.localizedRecoverySuggestion ?? nsError.localizedDescription
        }
        prompt(title: title, detail: detail, primary: "好") { _ in acknowledgement() }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .choosing
        let nsError = error as NSError
        let detail = nsError.domain == NSURLErrorDomain
            ? "网络连接失败，请稍后重试"
            : (nsError.localizedRecoverySuggestion ?? nsError.localizedDescription)
        prompt(title: "更新失败", detail: detail, primary: "好") { _ in acknowledgement() }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .downloading
        expectedBytes = 0
        receivedBytes = 0
        prompt(title: "正在下载", detail: targetVersion, progress: .indeterminate, secondary: "取消") { _ in cancellation() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard phase == .downloading else { return }
        expectedBytes = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard phase == .downloading else { return }
        let (sum, overflow) = receivedBytes.addingReportingOverflow(length)
        receivedBytes = overflow ? .max : sum
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        guard expectedBytes > 0 else {
            panel?.setProgress(.indeterminate, detail: targetVersion)
            return
        }
        let progress = min(1, Double(receivedBytes) / Double(expectedBytes))
        panel?.setProgress(.fraction(progress), detail: "\(targetVersion) · \(Int(progress * 100))%")
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting
        clearResponse()
        presentation.show(title: "准备安装", detail: targetVersion, progress: .indeterminate)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard phase == .extracting else { return }
        panel?.setProgress(progress.isFinite ? .fraction(max(0, min(1, progress))) : .indeterminate)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .choosing
        prompt(title: "更新已就绪", detail: targetVersion, primary: "安装并重启", secondary: "取消") { accepted in
            // .dismiss can still install on quit. .skip here cancels this installation only.
            reply(accepted ? .install : .skip)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        clearResponse()
        presentation.show(title: "正在安装", progress: .indeterminate,
            primaryTitle: applicationTerminated ? nil : "重试退出",
            primaryAction: applicationTerminated ? nil : retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .choosing
        // The old application bundle may no longer exist. Do not access it here.
        prompt(title: "更新完成", primary: "好") { _ in acknowledgement() }
    }

    func dismissUpdateInstallation() {
        phase = .idle
        clearResponse()
        expectedBytes = 0
        receivedBytes = 0
        targetVersion = ""
        panel?.dismiss()
        panel = nil
    }

    func showUpdateInFocus() { panel?.focus() }

    private var presentation: UpdatePanel {
        if let panel { return panel }
        let created = UpdatePanel()
        panel = created
        return created
    }

    private func clearResponse() {
        screen &+= 1
        response = nil
    }

    private func prompt(title: String, detail: String? = nil, progress: UpdatePanelProgress = .hidden,
                        primary: String? = nil, secondary: String? = nil, reply: @escaping (Bool) -> Void) {
        clearResponse()
        response = reply
        let token = screen
        presentation.show(title: title, detail: detail, progress: progress,
            primaryTitle: primary,
            primaryAction: primary == nil ? nil : { [weak self] in self?.respond(true, to: token) },
            secondaryTitle: secondary,
            secondaryAction: secondary == nil ? nil : { [weak self] in self?.respond(false, to: token) },
            onClose: { [weak self] in self?.respond(false, to: token) })
    }

    private func respond(_ accepted: Bool, to token: UInt64) {
        guard screen == token, let reply = response else { return }
        clearResponse()
        phase = .idle
        panel?.dismiss()
        reply(accepted)
    }
}
