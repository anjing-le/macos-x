import AppKit
import MacOSXCore

@main struct AboutRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var presented: [ObjectIdentifier] = [], links: [URL] = []
        let controller = AboutWindowController(info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "654"],
            presentWindow: { presented.append(ObjectIdentifier($0)) }, openLink: { links.append($0) })
        let window = controller.window!, content = controller.content
        precondition(!window.isVisible && presented.isEmpty && links.isEmpty)
        controller.present(); controller.present()
        precondition(presented.count == 2 && Set(presented).count == 1, "Reopening reuses the same nonmodal window")
        precondition(content.version.stringValue.contains("9.8.7") && content.version.stringValue.contains("654"), "Real bundle metadata is injected, never a hardcoded release")
        window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        for paragraph in content.paragraphs {
            let rect = paragraph.convert(paragraph.bounds, to: content)
            precondition(rect.minX >= 25 && rect.maxX <= content.bounds.maxX - 25 && rect.minY >= 25 && rect.maxY < content.bounds.maxY - 38, "Full readable paragraphs stay inside the page")
            let cell = paragraph.cell!
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: paragraph.bounds.width, height: 1000)).height
            precondition(paragraph.bounds.height + 1 >= needed, "No clipped last lines in either language")
        }
        let authorFrame = content.author.convert(content.author.bounds, to: content)
        let projectFrame = content.project.convert(content.project.bounds, to: content)
        precondition(projectFrame.minX >= authorFrame.maxX + 10 && projectFrame.maxX <= content.bounds.maxX - 25, "Localized link labels do not collide or spill outside the page")
        precondition(min(authorFrame.minY, projectFrame.minY) >= 24 && min(authorFrame.minY, projectFrame.minY) <= 40, "Page height follows its content without a large empty footer")
        precondition(NSApp.sendAction(content.author.action!, to: content.author.target, from: content.author))
        precondition(NSApp.sendAction(content.project.action!, to: content.project.target, from: content.project))
        precondition(links.map(\.absoluteString) == ["https://github.com/anjing-le", "https://github.com/anjing-le/macos-x"], "Links are explicit user actions, opened through injected handlers")
        if let folder = ProcessInfo.processInfo.environment["MACOSX_ABOUT_RENDER_DIR"] {
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: rep)
            let url = URL(fileURLWithPath: folder).appendingPathComponent("about-\(AppLanguage.current == .english ? "en" : "zh").png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
        }
        window.cancelOperation(nil); precondition(!window.isVisible)
        controller.present(); precondition(presented.count == 3 && Set(presented).count == 1)
        window.performClose(nil); precondition(!window.isVisible)
        let preview = AboutWindowController(info: [:], presentWindow: { _ in }, openLink: { _ in })
        precondition(preview.content.version.stringValue == AppLanguage.text("开发版本"))
        print("PASS about: real version, complete bilingual layout, repeated open/close and explicit author/project links; offscreen only, no user windows, browser, permissions or settings changes")
    }
}
