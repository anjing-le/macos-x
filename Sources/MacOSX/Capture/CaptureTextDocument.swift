import AppKit

enum CaptureClipboardContent {
    case image(CGImage, isText: Bool)
    case document(CaptureTextDocument)

    static func decode(images:[Data],text:String?,rtf:Data?,html:Data?) -> Self? {
        for data in images.prefix(4) {
            if let image = CaptureClipboard.image(from:data) { return .image(image,isText:false) }
        }
        if html == nil, rtf == nil, let text, !CaptureTextDocument.looksLikeMarkdown(text),
           let image = CaptureClipboard.text(text) { return .image(image,isText:true) }
        guard let document = CaptureTextDocument.decode(text:text,rtf:rtf,html:html) else { return nil }
        return .document(document)
    }
}

/// Preserve text semantics until the background renderer produces a complete
/// long image with native TextKit layout and a bounded pixel allocation.
struct CaptureTextDocument {
    static let maximumCharacters = 100_000
    static let maximumRichBytes = 4_000_000
    let attributed: NSAttributedString
    let source: String

    init(attributed:NSAttributedString,source:String) {
        let owned = NSAttributedString(attributedString:attributed)
        self.attributed = owned; self.source = source
    }

    static func decode(text: String?, rtf: Data?, html: Data?) -> Self? {
        if let text, !text.isEmpty {
            guard text.utf16.count <= maximumCharacters else { return nil }
            if looksLikeMarkdown(text) { return markdown(text) }
        }
        if let html, html.count <= maximumRichBytes,
           let value = String(data: html, encoding: .utf8) ?? String(data:html,encoding:.utf16),
           let markdown = CaptureClipboardHTML.markdown(value), !markdown.isEmpty {
            if let document = Self.markdown(markdown, source: text) { return document }
        }
        if let rtf, rtf.count <= maximumRichBytes,
           let rich = NSAttributedString(rtf: rtf, documentAttributes: nil),
           rich.length > 0, rich.length <= maximumCharacters {
            let safe = NSMutableAttributedString(attributedString: rich)
            var attachments: [NSRange] = []
            safe.enumerateAttribute(.attachment, in: NSRange(location:0,length:safe.length)) { value, range, _ in
                if value != nil { attachments.append(range) }
            }
            for range in attachments.reversed() { safe.replaceCharacters(in:range,with:"[附件]") }
            return .init(attributed:safe,source:text ?? safe.string)
        }
        guard let text, !text.isEmpty else { return nil }
        return markdown(text)
    }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        text.contains("**") || text.contains("```") || text.contains("|---")
            || text.range(of: #"(?m)^\s*(#{1,6}\s|\|.*\||[-*+]\s|\d+\.\s|>\s)"#, options:.regularExpression) != nil
    }

    static func markdown(_ source: String, source original: String? = nil) -> Self? {
        guard !source.isEmpty, source.utf16.count <= maximumCharacters else { return nil }
        let output = NSMutableAttributedString(string: "")
        let lines = source.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
        var index = 0, code = false
        func paragraph(_ text: String, size: CGFloat = 17, bold: Bool = false, indent: CGFloat = 0,
                       monospaced: Bool = false, blocks: [NSTextBlock] = [], background: NSColor? = nil,
                       alignment: NSTextAlignment = .left) {
            let value = inline(text, size:size, bold:bold, monospaced:monospaced)
            value.append(NSAttributedString(string:"\n",attributes:[.font:NSFont.systemFont(ofSize:size)]))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4; style.paragraphSpacing = blocks.isEmpty ? 8 : 3
            style.firstLineHeadIndent = indent; style.headIndent = indent
            style.textBlocks = blocks
            style.alignment = alignment
            value.addAttribute(.paragraphStyle,value:style,range:NSRange(location:0,length:value.length))
            if let background { value.addAttribute(.backgroundColor,value:background,range:NSRange(location:0,length:value.length)) }
            output.append(value)
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("```") { code.toggle(); index += 1; continue }
            if code {
                paragraph(line,size:15,indent:12,monospaced:true,background:NSColor(white:0.96,alpha:1)); index += 1; continue
            }
            if index + 1 < lines.count, let header = cells(line), let separator = cells(lines[index+1]),
               header.count == separator.count, header.count <= 12,
               separator.allSatisfy({ $0.range(of:#"^:?-{3,}:?$"#,options:.regularExpression) != nil }) {
                var rows = [header]; index += 2
                while index < lines.count, let row = cells(lines[index]), row.count == header.count {
                    rows.append(row); index += 1
                }
                let table = NSTextTable(); table.numberOfColumns = header.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
                let weights = header.indices.map { column in
                    sqrt(Double(min(160,rows.map { $0[column].count }.max() ?? 1) + 8))
                }
                let total = weights.reduce(0,+)
                for (rowIndex,row) in rows.enumerated() {
                    for (column,cell) in row.enumerated() {
                        let block = NSTextTableBlock(table:table,startingRow:rowIndex,rowSpan:1,startingColumn:column,columnSpan:1)
                        block.setValue(CGFloat(weights[column]/total*100),type:.percentageValueType,for:.width)
                        block.setWidth(7,type:.absoluteValueType,for:.padding)
                        block.setWidth(0.5,type:.absoluteValueType,for:.border)
                        block.setBorderColor(NSColor(white:0.78,alpha:1))
                        block.backgroundColor = rowIndex == 0 ? NSColor(calibratedRed:0.96,green:0.95,blue:0.92,alpha:1) : .white
                        let align: NSTextAlignment = separator[column].hasSuffix(":")
                            ? (separator[column].hasPrefix(":") ? .center : .right) : .left
                        paragraph(cell,size:16,bold:rowIndex == 0,blocks:[block],alignment:align)
                    }
                }
                paragraph("",size:4); continue
            }
            if trimmed.isEmpty { paragraph("",size:5); index += 1; continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                paragraph(String(trimmed.dropFirst(hashes+1)),size:hashes == 1 ? 25 : 21,bold:true)
            } else if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"),
                      trimmed.components(separatedBy:"**").count == 3 {
                paragraph(String(trimmed.dropFirst(2).dropLast(2)),size:20,bold:true)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                paragraph("•  " + trimmed.dropFirst(2),indent:10)
            } else if trimmed.hasPrefix("> ") {
                paragraph(String(trimmed.dropFirst(2)),indent:16,background:NSColor(white:0.97,alpha:1))
            } else if ["---","***","___"].contains(trimmed) {
                paragraph("────────────────────────",size:11)
            } else { paragraph(line) }
            index += 1
        }
        return .init(attributed:NSAttributedString(attributedString:output),source:original ?? source)
    }

    private static func inline(_ text: String, size: CGFloat, bold: Bool, monospaced: Bool) -> NSMutableAttributedString {
        let output = NSMutableAttributedString(string:"")
        guard !monospaced, let rich = try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string:text,attributes:[.font:monospaced ? NSFont.monospacedSystemFont(ofSize:size,weight:.regular) : NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular),.foregroundColor:NSColor(white:0.16,alpha:1)])
        }
        for run in rich.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize:size-1,weight:.regular)
                : NSFont.systemFont(ofSize:size,weight:bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized) { font = NSFont(descriptor:font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)),size:font.pointSize) ?? font }
            var attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor(white:0.16,alpha:1)]
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor(white:0.95,alpha:1) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https","http","mailto"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
            output.append(NSAttributedString(string:String(rich[run.range].characters),attributes:attributes))
        }
        return output
    }

    private static func cells(_ line: String) -> [String]? {
        var text = line.trimmingCharacters(in:.whitespaces)
        guard text.contains("|") else { return nil }
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], cell = "", escaped = false, code = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; cell.append(character); continue }
            if character == "`" { code.toggle() }
            if character == "|", !code { result.append(cell.trimmingCharacters(in:.whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        result.append(cell.trimmingCharacters(in:.whitespaces))
        return result.count > 1 ? result : nil
    }
}

/// Whitelist-only semantic HTML to Markdown. No DOM/WebView, scripts, styles,
/// images, file access or network loading. Clipboard HTML is untrusted input.
private enum CaptureClipboardHTML {
    static func markdown(_ input: String) -> String? {
        var source = input
        if let start = source.range(of:"<!--StartFragment-->"), let end = source.range(of:"<!--EndFragment-->"), start.upperBound <= end.lowerBound {
            source = String(source[start.upperBound..<end.lowerBound])
        }
        guard let regex = try? NSRegularExpression(pattern:#"(?s)<!--.*?-->|<[^>]{0,4096}>|[^<]+|<"#) else { return nil }
        var matches: [NSTextCheckingResult] = [], tooMany = false
        regex.enumerateMatches(in:source,range:NSRange(source.startIndex...,in:source)) { match, _, stop in
            guard let match else { return }
            if matches.count >= 30_000 { tooMany = true; stop.pointee = true }
            else { matches.append(match) }
        }
        guard !tooMany else { return nil }
        var output = "", skipped: [String] = [], cell = false, table = false, firstRow = false, columns = 0, pre = false
        var lists: [(ordered:Bool,index:Int)] = []
        for match in matches {
            guard let range = Range(match.range,in:source) else { continue }
            let token = String(source[range])
            if !token.hasPrefix("<") {
                guard skipped.isEmpty else { continue }
                guard token.utf8.count <= CaptureTextDocument.maximumCharacters * 4 else { return nil }
                let value = entities(token)
                if table, !cell, value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { continue }
                output += cell ? value.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"|",with:"\\|") : value
                guard output.utf8.count <= CaptureTextDocument.maximumCharacters * 4 else { return nil }
                continue
            }
            let closing = token.hasPrefix("</")
            let name = token.dropFirst(closing ? 2 : 1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }.lowercased()
            if ["script","style","head","iframe","object","svg"].contains(name) {
                if closing { if skipped.last == name { skipped.removeLast() } } else { skipped.append(name) }
                continue
            }
            guard skipped.isEmpty else { continue }
            switch name {
            case "table": table = !closing; firstRow = !closing; output += "\n\n"
            case "tr":
                if closing { output += "\n"; if firstRow, columns > 0 { output += "|" + Array(repeating:" --- |",count:columns).joined() + "\n" }; firstRow = false }
                else { output += "|"; columns = 0 }
            case "td","th": cell = !closing; if closing { output += " |" } else { columns += 1; output += " " }
            case "strong","b": output += "**"
            case "em","i": output += "*"
            case "pre": pre = !closing; output += closing ? "\n```\n" : "\n```\n"
            case "code": if !pre { output += "`" }
            case "h1","h2","h3","h4","h5","h6": output += closing ? "\n\n" : "\n\n" + String(repeating:"#",count:Int(name.suffix(1)) ?? 2) + " "
            case "p","div","section","article": if !table { output += "\n\n" } else if cell { output += " " }
            case "br": output += cell ? " " : "\n"
            case "ol","ul":
                if closing { if !lists.isEmpty { lists.removeLast() } }
                else { lists.append((name == "ol",0)) }
            case "li":
                if closing { output += "\n" }
                else if !lists.isEmpty, lists[lists.count-1].ordered {
                    lists[lists.count-1].index += 1; output += "\n\(lists[lists.count-1].index). "
                } else { output += "\n- " }
            case "blockquote": output += closing ? "\n" : "\n> "
            case "img": output += "[图片]"
            default: break
            }
        }
        return output.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    private static func entities(_ text: String) -> String {
        var value = text
        for (from,to) in [("&nbsp;"," "),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&apos;","'")] { value = value.replacingOccurrences(of:from,with:to) }
        if let regex = try? NSRegularExpression(pattern:#"&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});"#) {
            let matches = regex.matches(in:value,range:NSRange(value.startIndex...,in:value))
            for match in matches.reversed() {
                guard let range = Range(match.range,in:value), let numberRange = Range(match.range(at:1),in:value) else { continue }
                let number = String(value[numberRange]), hex = number.hasPrefix("x")
                if let raw = UInt32(hex ? String(number.dropFirst()) : number,radix:hex ? 16 : 10), let scalar = UnicodeScalar(raw) { value.replaceSubrange(range,with:String(scalar)) }
            }
        }
        return value.replacingOccurrences(of:"&amp;",with:"&")
    }
}
