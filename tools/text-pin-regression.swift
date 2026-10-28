import AppKit
import ImageIO

@main struct TextPinRegression {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); count += 1 }
        let sample = """
        # 图文排版示例

        一段介绍，包含 **重点加粗**、*斜体*、`代码` 和普通正文。

        **一、对比信息**

        | 比较项目 | 方案甲的约定 | 方案乙的情况 | 如何理解 |
        | --- | --- | --- | --- |
        | **人员衔接** | 这里是比较长的一段内容，应该在单元格内部换行，不应越过表格边框 | 明确的说明 | 第一行完整保留 |
        | 费用说明 | **两项合计**，需核对适用条件 | 另有约定 | 不能直接相加 |

        - **第一项**：列表保留重点。
        - 第二项：文字仍然清晰可读。

        **二、数字展示**

        | 项目 | 数值甲 | 数值乙 |
        | :--- | ---: | :---: |
        | 示例一 | 80 | 100 |
        | 示例二 | 5% | 10% |

        > 引用内容应该有缩进。

        ```swift
        let example = "保留代码，不解释为操作"
        ```

        """
        let long = sample + (0..<180).map { "第 \($0) 段，长文保持正常字号，不缩成小字。\n" }.joined() + "全文结束标记-END"
        let document = CaptureTextDocument.decode(text:long,rtf:nil,html:nil)!
        check(long.utf16.count > 4096,"Fixture exceeds old text cap")
        check(document.attributed.string.contains("全文结束标记-END"),"Long document retains its final paragraph")
        check(!document.attributed.string.contains("**重点加粗**"),"Markdown delimiters become presentation attributes")
        let heading = (document.attributed.string as NSString).range(of:"图文排版示例")
        check((document.attributed.attribute(.font,at:heading.location,effectiveRange:nil) as! NSFont).pointSize >= 21,"Heading hierarchy")
        let bold = (document.attributed.string as NSString).range(of:"重点加粗"), regular = (document.attributed.string as NSString).range(of:"一段介绍")
        let boldFont = document.attributed.attribute(.font,at:bold.location,effectiveRange:nil) as! NSFont
        let regularFont = document.attributed.attribute(.font,at:regular.location,effectiveRange:nil) as! NSFont
        check(boldFont.fontName != regularFont.fontName,"Bold is an actual font difference")
        var tables = Set<ObjectIdentifier>(), tableCells = 0
        document.attributed.enumerateAttribute(.paragraphStyle,in:NSRange(location:0,length:document.attributed.length)) { value,_,_ in
            for block in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                if let block = block as? NSTextTableBlock { tables.insert(ObjectIdentifier(block.table)); tableCells += 1 }
            }
        }
        check(tables.count == 2 && tableCells >= 20,"Distinct tables retain their cells")
        let html = """
        <html><head><style>DO_NOT_RENDER_CSS</style></head><body><script>DO_NOT_RENDER_SCRIPT</script>
        <h2>标题</h2><p>普通文字 <strong>强调</strong> 与 &lt;符号&gt;</p>
        <table>\n<tr><th>项目</th><th>结果</th></tr>\n<tr><td>第一行</td><td><b>42</b></td></tr>\n</table>
        <img src="https://invalid.example/must-not-fetch.png"></body></html>
        """
        let htmlDocument = CaptureTextDocument.decode(text:"标题 普通文字 强调",rtf:nil,html:Data(html.utf8))!
        check(htmlDocument.attributed.string.contains("第一行") && htmlDocument.attributed.string.contains("42"),"Pretty-printed HTML retains table body rows")
        check(!htmlDocument.attributed.string.contains("DO_NOT_RENDER") && !htmlDocument.attributed.string.contains("must-not-fetch"),"No scripts, styles or external image URLs enter layout")
        check(htmlDocument.attributed.string.contains("<符号>"),"HTML text entities")
        let rtfSource = NSAttributedString(string:"富文本加粗",attributes:[.font:NSFont.boldSystemFont(ofSize:18)])
        let rtf = try rtfSource.data(from:NSRange(location:0,length:rtfSource.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        let rich = CaptureTextDocument.decode(text:"富文本加粗",rtf:rtf,html:nil)!
        check((rich.attributed.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true,"RTF survives when plain text also exists")
        check(CaptureTextDocument.markdown(String(repeating:"x",count:100_001)) == nil,"Bounded preparation without truncation")
        if case .document = CaptureClipboardContent.decode(images:[],text:long,rtf:nil,html:nil) { check(true,"Long content routes to a document") } else { check(false,"Long document route") }
        if case .image(_,let isText) = CaptureClipboardContent.decode(images:[],text:"短文字",rtf:nil,html:nil) { check(isText,"Compact text retains image behavior") } else { check(false,"Short text route") }
        let image = CaptureTextPin.image(document: document)!
        let png = CaptureTextPin.encodePNG(image)!
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        check(decoded.width == image.width && decoded.height == image.height, "PNG contains the whole image")
        let repinned = CaptureClipboard.image(from: png)!
        check(repinned.width == image.width && repinned.height == image.height,
              "Copying and re-pinning a long PNG retains its source resolution instead of shrinking to 2200 pixels")
        check(CapturePinTransform().render(image) != nil, "Ordinary image copy and save accept the complete long image")
        var rotated = CapturePinTransform(); rotated.rotate(clockwise: true)
        let rotatedImage = rotated.render(image)!
        check(rotatedImage.width == image.height && rotatedImage.height == image.width,
              "Long-image rotation retains all pixels within the image budget")
        check(image.height > 1800 && image.width == 880, "Long text becomes a complete tall image at readable source width")
        let sampler = CapturePixelSampler(image: image)!
        var lastInk = -1
        for y in max(0, image.height - 70)..<image.height {
            for x in 0..<image.width where sampler.sample(x: x, y: y)!.red < 120 { lastInk = y; break }
        }
        check(lastInk > image.height - 50, "Final paragraph is painted near the image bottom, not clipped to a viewport")
        let available = CGRect(x: -1440, y: 80, width: 1440, height: 860)
        let frame = CaptureTextPin.initialFrame(image: image, available: available)
        check(available.contains(frame) && abs(frame.width / frame.height - CGFloat(image.width) / CGFloat(image.height)) < 0.0001,
              "Initial long-image frame fits a negative-coordinate display without changing its aspect")
        let maximumZoom = CaptureTextPin.maximumZoom(image: image, baseSize: frame.size)
        check(maximumZoom >= CGFloat(image.width) / frame.width && maximumZoom > 4,
              "Long-image zoom can reach native pixels beyond the former 400-percent thumbnail limit")
        let ticket = CaptureImageService.Ticket(); ticket.cancel()
        check(CaptureTextPin.image(document: document, ticket: ticket) == nil, "Cancelled preparation does not create an image")
        let letterImage = CaptureTextPin.image(document: CaptureTextDocument.markdown("F")!)!
        let letterSampler = CapturePixelSampler(image: letterImage)!
        var rows: [Int] = []
        for y in 0..<letterImage.height {
            var ink = 0
            for x in 0..<letterImage.width { if letterSampler.sample(x: x, y: y)!.red < 100 { ink += 1 } }
            rows.append(ink)
        }
        let first = rows.firstIndex(where: { $0 > 0 })!, last = rows.lastIndex(where: { $0 > 0 })!, middle = (first + last) / 2
        check(rows[first...middle].reduce(0,+) > rows[(middle+1)...last].reduce(0,+),
              "Native glyphs remain upright, not mirrored vertically")
        let compact = CaptureTextPin.image(document: CaptureTextDocument.markdown("**重点提示**\n简短内容")!)!
        check(compact.width < 450 && compact.height < 300, "Short formatted content has close-fitting margins")
        let enormous = CaptureTextDocument.markdown(String(repeating: "完整内容\n", count: 6000) + "最后一行-END")!
        let bounded = CaptureTextPin.image(document: enormous)!
        check(bounded.width * bounded.height <= CaptureTextPin.maximumPixels && bounded.height <= CaptureTextPin.maximumEdge,
              "Very long content stays within pixel and edge budgets instead of disappearing")
        check(bounded.height > image.height, "An oversized document still produces one complete long image")
        check(CapturePinTransform().render(bounded) != nil,
              "The bounded maximum-edge image can pass through the actual image-copy renderer")
        let tiledSampler = CapturePixelSampler(image: bounded,
            maximumBytes: CaptureRaster.pinMaximumPixels(for: bounded) * 4, tiled: true)!
        check(tiledSampler.byteCount <= 64 * 64 * 4 && tiledSampler.sample(x: 0, y: bounded.height - 1) != nil,
              "Very long image color picking reaches the last row with only a small tile buffer")
        let tail = bounded.cropping(to: CGRect(x: 0, y: bounded.height - 64, width: bounded.width, height: 64))!
        let boundedSampler = CapturePixelSampler(image: tail)!
        var bottomHasInk = false
        for y in max(0, tail.height - 20)..<tail.height {
            for x in 0..<tail.width where boundedSampler.sample(x: x, y: y)!.red < 180 { bottomHasInk = true; break }
        }
        check(bottomHasInk, "Adaptive density preserves the last line of an oversized document")
        if let path = ProcessInfo.processInfo.environment["MACOSX_TEXT_DOCUMENT_PREVIEW"] {
            try png.write(to: URL(fileURLWithPath: path)); print("Offscreen preview: \(image.width)×\(image.height)")
            if let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(1200, image.height))),
               let data = CaptureTextPin.encodePNG(top) {
                try data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-top.png")))
            }
        }
        print("PASS formatted long-image pins: \(count) assertions; native offline layout, complete tables, end-of-document pixels, bounded raster and zoom; no presented windows or general clipboard writes")
    }
}
