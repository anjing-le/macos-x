// Compiled in the same isolated unit as PromptSettingsView. No installed
// preferences, visible file picker or general clipboard are used.
extension PromptSettingsView {
    @MainActor static func checkPolishFixture() throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            precondition(condition(), "Import fixture timed out")
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        func document(_ title: String) -> Data {
            Data("{\"version\":1,\"prompts\":[{\"id\":\"imported\",\"title\":\"\(title)\",\"content\":\"完整正文\"}]}".utf8)
        }
        let collection = PromptCollection(legacy: (1...10).map { .init(title: "位置\($0)", content: "正文\($0)") })
        let view = PromptSettingsView(collection: collection, presentation: .init())
        var changes = 0; view.onChange = { _ in changes += 1 }
        view.parseData(document("关闭前")); precondition(view.importTask != nil && !view.importer.isEnabled)
        view.endInteraction(); settle()
        precondition(view.importTask == nil && view.pending == nil && view.importer.title == "导入 JSON" && view.importer.isEnabled)
        precondition(view.collection == collection && changes == 0, "Closed import cannot mutate UI or data")
        view.parseData(document("旧请求")); view.parseData(document("最新请求"))
        wait { view.importTask == nil }; settle()
        precondition(view.pending?.prompts.first?.title == "最新请求" && view.collection == collection)
        view.importPressed()
        precondition(view.collection.prompts.contains { $0.id == "imported" && $0.title == "最新请求" } && changes == 1)
        view.parseData(document("取消")); view.cancelPendingImport(); settle()
        precondition(view.pending == nil && view.importTask == nil && view.importer.isEnabled && view.cancelImport.isHidden)
        view.parseData(Data("invalid".utf8)); wait { view.importTask == nil }
        precondition(view.pending == nil && view.importer.isEnabled && view.cancelImport.isHidden && !view.status.stringValue.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try document("文件读取取消").write(to: file)
        let beforeFile = view.collection
        view.readImportFile(file); view.endInteraction(); settle()
        precondition(view.pending == nil && view.collection == beforeFile && view.importer.isEnabled)
        view.readImportFile(file); wait { view.importTask == nil && view.pending != nil }
        precondition(view.pending?.prompts.first?.title == "文件读取取消")
        view.cancelPendingImport()
        let suite = "cc.anjing.macos-x.polish.fixture.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let module = PhraseWheelModule(defaults: defaults)
        let cached = module.settingsView as! PromptSettingsView
        cached.parseData(document("停用前")); module.stop(); settle()
        precondition(cached.pending == nil && cached.importTask == nil && cached.importer.isEnabled)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { view.endInteraction(); window.close() }
        view.selectSlot(0)
        let preview = view.presentationPreview!, field = preview.search
        field.stringValue = "位置"; preview.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        for index in 0..<30 {
            view.body.string = "新的完整正文 \(index)"; view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.body))
            precondition(view.presentationPreview === preview && field.stringValue == "位置", "Body edits reuse controls and preserve preview search")
        }
        precondition(view.collection.prompts[0].content == "新的完整正文 29")
        let encodedSize = try JSONEncoder().encode(view.collection).count
        precondition(view.encodedSize == encodedSize)
        view.titleField.stringValue = "新标题"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.titleField))
        precondition(view.presentationPreview === preview && view.picker.item(at: 1)?.title == "新标题")
        view.showLibrary(); view.search.stringValue = "新标题"; view.filterRows()
        precondition(view.rows == [0], "Renamed entry remains searchable")
        view.body.string = ""; view.changed(); precondition(view.collection.prompts[0].content.isEmpty)
        view.endInteraction(); view.parseData(document("实际关闭")); window.close(); settle()
        precondition(view.pending == nil && view.importTask == nil, "Native window close rejects the pending completion")
        print("PASS prompt polish: cancelled/closed/stopped/file/latest imports, explicit confirmation, incremental edit identity/search/title/capacity; isolated native controls")
    }
}

extension Check {
    @MainActor static func checkPromptPolish() throws { try PromptSettingsView.checkPolishFixture() }
}
