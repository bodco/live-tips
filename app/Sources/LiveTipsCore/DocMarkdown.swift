import Foundation

/// Pacenote 0.9.5.2 (owner: "a header in Notion must be a header in Google Docs and Word too, not ##"): the export's
/// Markdown read once into blocks, then written as real Word headings and lists (.docx, also uploaded to Google
/// Docs, which keeps Word's heading styles), Notion blocks with bold and nested bullets, and HTML for Copy.
public enum DocMD {
    public struct Run: Equatable {
        public var text: String; public var bold = false; public var italic = false; public var code = false
        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
            self.text = text; self.bold = bold; self.italic = italic; self.code = code
        }
    }
    public enum Kind: Equatable { case h1, h2, h3, h4, para, bullet(Int), todo(Bool), quote, rule }
    public struct Block: Equatable {
        public var kind: Kind; public var runs: [Run]
        public init(_ kind: Kind, _ runs: [Run]) { self.kind = kind; self.runs = runs }
        public var plain: String { runs.map(\.text).joined() }
    }

    // MARK: reading

    /// **bold**, *italic* (or _italic_ at word edges) and `code`; anything unclosed stays as typed.
    public static func inline(_ s: String) -> [Run] {
        var out: [Run] = []
        var buf = ""
        var bold = false, italic = false
        let c = Array(s)
        var i = 0
        func flush() { if !buf.isEmpty { out.append(Run(buf, bold: bold, italic: italic)); buf = "" } }
        func closes(_ m: String, from: Int) -> Bool {
            let mm = Array(m)
            var j = from
            while j + mm.count <= c.count { if Array(c[j..<(j + mm.count)]) == mm { return true }; j += 1 }
            return false
        }
        while i < c.count {
            if c[i] == "`", let end = c[(i + 1)...].firstIndex(of: "`") {
                flush(); out.append(Run(String(c[(i + 1)..<end]), code: true)); i = end + 1; continue
            }
            if c[i] == "*", i + 1 < c.count, c[i + 1] == "*", bold || closes("**", from: i + 2) {
                flush(); bold.toggle(); i += 2; continue
            }
            if c[i] == "*", italic || (i + 1 < c.count && c[i + 1] != " " && c[i + 1] != "*" && closes("*", from: i + 1)) {
                flush(); italic.toggle(); i += 1; continue
            }
            if c[i] == "_", (italic && (i + 1 == c.count || !c[i + 1].isLetter)) ||
                (!italic && (i == 0 || !c[i - 1].isLetter) && i + 1 < c.count && c[i + 1] != " " && closes("_", from: i + 1)) {
                flush(); italic.toggle(); i += 1; continue
            }
            buf.append(c[i]); i += 1
        }
        flush()
        return out.isEmpty ? [Run("")] : out
    }

    public static func parse(_ md: String) -> [Block] {
        var out: [Block] = []
        for raw in md.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l == "---" || l == "***" { out.append(Block(.rule, [])); continue }
            if let r = l.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let n = l[r].filter { $0 == "#" }.count
                out.append(Block(n == 1 ? .h1 : n == 2 ? .h2 : n == 3 ? .h3 : .h4, inline(String(l[r.upperBound...])))); continue
            }
            if let r = l.range(of: "^[-*\u{2022}]\\s+\\[( |x|X)\\]\\s+", options: .regularExpression) {
                out.append(Block(.todo(l[r].lowercased().contains("x")), inline(String(l[r.upperBound...])))); continue
            }
            if let r = l.range(of: "^([-*\u{2022}]|[0-9]{1,3}[.)])\\s+", options: .regularExpression) {
                out.append(Block(.bullet(min(indent / 2, 2)), inline(String(l[r.upperBound...])))); continue
            }
            if l.hasPrefix("> ") { out.append(Block(.quote, inline(String(l.dropFirst(2))))); continue }
            out.append(Block(.para, inline(l)))
        }
        return out
    }

    // MARK: HTML (Copy as rich text)

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func htmlRuns(_ r: [Run]) -> String {
        r.map { x in
            var t = esc(x.text)
            if x.code { t = "<code>" + t + "</code>" }
            if x.italic { t = "<em>" + t + "</em>" }
            if x.bold { t = "<strong>" + t + "</strong>" }
            return t
        }.joined()
    }

    public static func html(_ blocks: [Block]) -> String {
        var out = "", depth = 0
        func close(to d: Int) { while depth > d { out += "</ul>"; depth -= 1 } }
        for b in blocks {
            switch b.kind {
            case .bullet(let lv):
                let want = lv + 1
                while depth < want { out += "<ul>"; depth += 1 }
                close(to: want)
                out += "<li>" + htmlRuns(b.runs) + "</li>"
            case .todo(let on):
                close(to: 0); out += "<p>" + (on ? "\u{2611} " : "\u{2610} ") + htmlRuns(b.runs) + "</p>"
            default:
                close(to: 0)
                switch b.kind {
                case .h1: out += "<h1>" + htmlRuns(b.runs) + "</h1>"
                case .h2: out += "<h2>" + htmlRuns(b.runs) + "</h2>"
                case .h3: out += "<h3>" + htmlRuns(b.runs) + "</h3>"
                case .h4: out += "<h4>" + htmlRuns(b.runs) + "</h4>"
                case .quote: out += "<blockquote>" + htmlRuns(b.runs) + "</blockquote>"
                case .rule: out += "<hr>"
                default: out += "<p>" + htmlRuns(b.runs) + "</p>"
                }
            }
        }
        close(to: 0)
        return "<meta charset=\"utf-8\">" + out
    }

    // MARK: Notion

    static func notionText(_ r: [Run]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for x in r where !x.text.isEmpty {
            var s = Substring(x.text.replacingOccurrences(of: "\u{2014}", with: "-"))
            while !s.isEmpty {
                var o: [String: Any] = ["type": "text", "text": ["content": String(s.prefix(1900))]]
                if x.bold || x.italic || x.code { o["annotations"] = ["bold": x.bold, "italic": x.italic, "code": x.code] }
                out.append(o); s = s.dropFirst(1900)
            }
        }
        return out
    }

    /// Notion blocks; "# " (the page title) is left out; a bullet one level in becomes a child of the bullet above.
    public static func notion(_ blocks: [Block], skipTitle: Bool = true) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var lastTop: Int? = nil                 // index in out of the last top-level bullet
        for b in blocks {
            func blk(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
                var body: [String: Any] = ["rich_text": notionText(b.runs)]
                for (k, v) in extra { body[k] = v }
                return ["object": "block", "type": type, type: body]
            }
            switch b.kind {
            case .h1: if !skipTitle { out.append(blk("heading_1")) }; lastTop = nil
            case .h2: out.append(blk("heading_2")); lastTop = nil
            case .h3, .h4: out.append(blk("heading_3")); lastTop = nil
            case .todo(let on): out.append(blk("to_do", ["checked": on])); lastTop = nil
            case .quote: out.append(blk("quote")); lastTop = nil
            case .rule: out.append(["object": "block", "type": "divider", "divider": [String: Any]()]); lastTop = nil
            case .bullet(let lv):
                let item = blk("bulleted_list_item")
                if lv > 0, let i = lastTop, var parent = out[i]["bulleted_list_item"] as? [String: Any] {
                    var kids = parent["children"] as? [[String: Any]] ?? []
                    kids.append(item); parent["children"] = kids; out[i]["bulleted_list_item"] = parent
                } else { out.append(item); lastTop = out.count - 1 }
            case .para: out.append(blk("paragraph")); lastTop = nil
            }
        }
        return out
    }

    // MARK: Word (.docx), real heading styles and bullet lists

    static func xesc(_ s: String) -> String { esc(s).replacingOccurrences(of: "\"", with: "&quot;") }

    static func wRuns(_ r: [Run]) -> String {
        r.map { x in
            var pr = ""
            if x.bold { pr += "<w:b/>" }
            if x.italic { pr += "<w:i/>" }
            if x.code { pr += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
            return "<w:r>" + (pr.isEmpty ? "" : "<w:rPr>" + pr + "</w:rPr>") + "<w:t xml:space=\"preserve\">" + xesc(x.text) + "</w:t></w:r>"
        }.joined()
    }

    public static func documentXML(_ blocks: [Block]) -> String {
        var body = ""
        for b in blocks {
            func p(_ style: String, _ extra: String = "", _ runs: String) -> String {
                "<w:p><w:pPr>" + (style.isEmpty ? "" : "<w:pStyle w:val=\"\(style)\"/>") + extra + "</w:pPr>" + runs + "</w:p>"
            }
            switch b.kind {
            case .h1: body += p("Title", "", wRuns(b.runs))
            case .h2: body += p("Heading1", "", wRuns(b.runs))
            case .h3: body += p("Heading2", "", wRuns(b.runs))
            case .h4: body += p("Heading3", "", wRuns(b.runs))
            case .bullet(let lv): body += p("ListParagraph", "<w:numPr><w:ilvl w:val=\"\(lv)\"/><w:numId w:val=\"1\"/></w:numPr>", wRuns(b.runs))
            case .todo(let on): body += p("ListParagraph", "", wRuns([Run(on ? "\u{2611} " : "\u{2610} ")] + b.runs))
            case .quote: body += p("Quote", "", wRuns(b.runs))
            case .rule: body += p("", "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr>", "")
            case .para: body += p("", "", wRuns(b.runs))
            }
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
    }

    static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="200"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="23"/><w:szCs w:val="23"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="567"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>
    </w:styles>
    """

    static var numberingXML: String {
        let lv = (0..<3).map { i in
            "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(["\u{2022}", "\u{25E6}", "\u{25AA}"][i])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * i)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>" + lv + "</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
    }

    /// Word 2013+ mode, so Word does not open the file in Compatibility Mode.
    static let settingsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

    public static func docx(_ blocks: [Block]) -> Data {
        let ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/><Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/></Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let docRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/></Relationships>"
        return Zip.stored([("[Content_Types].xml", Data(ct.utf8)), ("_rels/.rels", Data(rels.utf8)),
                           ("word/_rels/document.xml.rels", Data(docRels.utf8)), ("word/document.xml", Data(documentXML(blocks).utf8)),
                           ("word/styles.xml", Data(stylesXML.utf8)), ("word/numbering.xml", Data(numberingXML.utf8)),
                           ("word/settings.xml", Data(settingsXML.utf8))])
    }
}

/// A zip without compression (enough for a .docx), no dependency.
public enum Zip {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    public static func stored(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let time = 0, date = (2026 - 1980) << 9 | 1 << 5 | 1
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), off = UInt32(out.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(time, &out); u16(date, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(data)
            u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(time, &central); u16(date, &central); u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
            u16(n.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(off, &central)
            central.append(n)
        }
        let cdOff = UInt32(out.count)
        out.append(central)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(cdOff, &out); u16(0, &out)
        return out
    }
}
