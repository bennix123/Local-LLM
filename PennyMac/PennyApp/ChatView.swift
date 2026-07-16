import SwiftUI

/// The center column — header + scrollback + input. Folds together
/// `ChatArea.jsx`, `Message.jsx` and `InputBar.jsx` from the React frontend.
struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @State private var draft = ""

    private let starters: [(emoji: String, title: String, sub: String, action: String)] = [
        ("🔥", "Roast me", "Brutal honesty about your spending.", "roast"),
        ("👻", "Banish zombie subs", "Find recurring subs you forgot you had.", "ghosts"),
        ("📊", "Spending patterns", "What Penny notices across your statements.", "patterns"),
        ("📈", "Compound my savings", "If I fix the leaks, what's it worth?", "compound"),
    ]

    private let chips: [(label: String, action: String)] = [
        ("🔥 Roast my spending", "roast"),
        ("👻 Banish zombie subs", "ghosts"),
        ("⛅ Forecast savings", "forecast"),
        ("📈 Compound math", "compound"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            scrollback
            inputBar
        }
        .background(Theme.paper)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                PennyWordmark(size: 20)
                Text("running locally · ready · \(app.modelDisplayName)")
                    .font(Theme.font(11)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button { app.newChat() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: scrollback

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if app.messages.isEmpty {
                    emptyState.padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(app.messages) { msg in
                            // Skip the not-yet-streamed assistant placeholder — the typing
                            // indicator represents it (otherwise its lone avatar duplicates).
                            if !(msg.role == .assistant && msg.content.isEmpty) {
                                MessageBubble(message: msg).id(msg.id)
                            }
                        }
                        if app.isThinking, app.messages.last?.content.isEmpty == true {
                            TypingIndicator().id("typing")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                }
            }
            .onChange(of: app.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return VStack(spacing: 14) {
            Text("ask penny anything about your money")
                .font(Theme.font(15, .semibold)).foregroundStyle(Theme.dim)
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(starters, id: \.action) { s in
                    Button { app.runFlow(s.action) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.emoji).font(.system(size: 22))
                            Text(s.title).font(Theme.font(14, .bold)).foregroundStyle(Theme.ink)
                            Text(s.sub).font(Theme.font(11)).foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: input

    private var inputBar: some View {
        VStack(spacing: 8) {
            if app.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.action) { chip in
                            Button { app.runFlow(chip.action) } label: {
                                Text(chip.label).font(Theme.font(12, .semibold)).foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Theme.card, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(spacing: 8) {
                TextField("ask penny anything... e.g. why am i broke?", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.ink)   // explicit: never white-on-cream
                    .tint(Theme.limeD)             // brand-colored caret
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1.5))
                    .onSubmit(sendDraft)
                    .disabled(app.isThinking)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Theme.lime : Theme.line, in: Circle())
                        .overlay(Circle().stroke(Theme.ink.opacity(canSend ? 1 : 0), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.paper)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private var canSend: Bool {
        !app.isThinking && !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        app.send(draft)
        draft = ""
    }
}

// MARK: - Message bubble (Message.jsx)

struct MessageBubble: View {
    let message: ChatMessage

    // Tables need room for many columns; prose stays narrow for readability.
    private var maxBubbleWidth: CGFloat {
        if message.role == .user { return 440 }
        return MD.hasTable(message.content) ? 820 : 560
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                PennyAvatar(size: 24, mood: message.content.isEmpty ? .thinking : .happy)
            } else {
                Spacer(minLength: 40)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant, let engine = message.engine, !message.content.isEmpty {
                    Text("⚡ \(engine.uppercased()) ENGINE")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.limeS, in: Capsule())
                        .overlay(Capsule().stroke(Theme.limeD, lineWidth: 1.5))
                }
                if !message.content.isEmpty {
                    Group {
                        if message.role == .user {
                            Text(message.content)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.ink)
                        } else {
                            ChatMarkdown(text: message.content)   // renders markdown tables as grids
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(message.role == .user ? Theme.lime : Theme.card,
                                in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.line, lineWidth: 1))
                    .frame(maxWidth: maxBubbleWidth,
                           alignment: message.role == .user ? .trailing : .leading)
                }
            }
            if message.role == .user {
                // trailing bubble; no avatar
            } else {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Typing indicator (the three-dot bubble)

struct TypingIndicator: View {
    @State private var t = 0.0
    var body: some View {
        HStack(spacing: 8) {
            PennyAvatar(size: 24, mood: .thinking)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.dim)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * abs(sin(t + Double(i) * 0.6)))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.line, lineWidth: 1))
            Spacer(minLength: 40)
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { t = .pi * 2 }
        }
    }
}

// MARK: - Chat markdown (renders GitHub-style pipe tables as real grids)

/// Minimal markdown renderer for assistant replies — the SwiftUI analogue of the
/// React `mdToHtml`. It splits the text into paragraphs and tables: paragraphs get
/// inline **bold**/*italic*/`code` via AttributedString; tables become aligned
/// grids (numeric/money columns right-aligned) instead of raw `| … | … |` text.
struct ChatMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MD.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    Text(MD.inline(s))
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let headers, let rows, let aligns):
                    // No greedy ScrollView here — it would stretch the whole bubble
                    // to full width. The grid sizes to its content so the bubble hugs it.
                    MDTable(headers: headers, rows: rows, aligns: aligns)
                }
            }
        }
    }
}

private struct MDTable: View {
    let headers: [String]
    let rows: [[String]]
    let aligns: [TextAlignment]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow {
                ForEach(headers.indices, id: \.self) { c in
                    Text(headers[c])
                        .font(Theme.font(11.5, .heavy))
                        .foregroundStyle(Theme.ink)
                        .gridColumnAlignment(aligns[safe: c] == .trailing ? .trailing : .leading)
                }
            }
            Divider().overlay(Theme.line).gridCellColumns(max(headers.count, 1))
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(headers.indices, id: \.self) { c in
                        let value = rows[r][safe: c] ?? ""
                        Text(value)
                            .font(Theme.font(11.5))
                            .foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

/// Tiny block-level markdown parser: paragraphs + pipe tables.
enum MD {
    enum Block {
        case paragraph(String)
        case table(headers: [String], rows: [[String]], aligns: [TextAlignment])
    }

    static func hasTable(_ text: String) -> Bool {
        parse(text).contains { if case .table = $0 { return true }; return false }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var para: [String] = []
        var i = 0

        func flush() {
            let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            para.removeAll()
        }

        while i < lines.count {
            if isRow(lines[i]), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let headers = cells(lines[i])
                i += 2
                var rows: [[String]] = []
                while i < lines.count, isRow(lines[i]), !isSeparator(lines[i]) {
                    var r = cells(lines[i])
                    while r.count < headers.count { r.append("") }
                    rows.append(r)
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows, aligns: alignments(headers, rows)))
            } else {
                para.append(lines[i])
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func isRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).contains("|")
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.replacingOccurrences(of: " ", with: "")
        guard t.contains("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-:".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Right-align columns whose data is mostly numeric (money/amounts).
    private static func alignments(_ headers: [String], _ rows: [[String]]) -> [TextAlignment] {
        headers.indices.map { c in
            let vals = rows.compactMap { $0[safe: c] }.filter { !$0.isEmpty }
            guard !vals.isEmpty else { return .leading }
            let numeric = vals.filter { isNumeric($0) }.count
            return numeric * 2 >= vals.count ? .trailing : .leading
        }
    }

    private static func isNumeric(_ s: String) -> Bool {
        let cleaned = s.filter { !"₹£$€%, ".contains($0) }
        guard !cleaned.isEmpty else { return false }
        var seenDot = false
        for (i, ch) in cleaned.enumerated() {
            if ch == "-" && i == 0 { continue }
            if ch == "." && !seenDot { seenDot = true; continue }
            if !ch.isNumber { return false }
        }
        return cleaned.contains { $0.isNumber }
    }

    /// Inline **bold** / *italic* / `code`, preserving line breaks.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
