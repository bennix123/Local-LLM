import SwiftUI
import AppKit   // NSPasteboard for the per-message Copy action

/// The center column — header + scrollback + input. Folds together
/// `ChatArea.jsx`, `Message.jsx` and `InputBar.jsx` from the React frontend.
struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @State private var draft = ""

    // The template's `.qsg` quick-start cards, gradient fills included.
    private let starters: [(emoji: String, title: String, sub: String, action: String,
                            from: UInt, to: UInt)] = [
        ("🔥", "Roast me", "Brutal honesty about your spending.", "roast", 0xffe4e1, 0xffcfc7),
        ("👻", "Banish zombie subs", "Find recurring subs you forgot you had.", "ghosts", 0xf3e8ff, 0xe9d5ff),
        ("⚡", "Spending patterns", "What Penny notices across your statements.", "patterns", 0xfef3c7, 0xfde68a),
        ("📈", "Compound my savings", "If I fix the leaks, what's it worth?", "compound", 0xdcfce7, 0xbbf7d0),
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

    @State private var pulsing = false

    private var header: some View {
        HStack(spacing: 11) {
            PennyAvatar(size: 56, mood: app.isThinking ? .thinking : .happy)
            VStack(alignment: .leading, spacing: 2) {
                PennyWordmark(size: 17, design: .serif)
                HStack(spacing: 5) {
                    Circle().fill(Theme.limeD).frame(width: 5, height: 5)
                        .opacity(pulsing ? 0.4 : 1)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true),
                                   value: pulsing)
                    Text("running locally · ready · \(app.modelDisplayName)")
                        .font(Theme.mono(9.5)).foregroundStyle(Theme.limeD)
                }
            }
            Spacer()
            Button { app.newChat() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .onAppear { if !TestMode.freezeAnimations { pulsing = true } }
    }

    // MARK: scrollback

    private var scrollback: some View {
        ScrollViewReader { proxy in
            Group {
                if app.messages.isEmpty {
                    // Not scrollable — a fixed column so the starter cards can pin
                    // to the bottom edge, just above the input bar.
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(app.messages) { msg in
                                // Skip the not-yet-streamed assistant placeholder — the typing
                                // indicator represents it (otherwise its lone avatar duplicates).
                                if !(msg.role == .assistant && msg.content.isEmpty) {
                                    MessageBubble(message: msg, isLast: msg.id == app.messages.last?.id)
                                        .id(msg.id)
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
            }
            .onChange(of: app.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let name = app.userName.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(name.isEmpty ? "hey, i'm all yours ☀️" : "morning \(name) ☀️")
                    .font(Theme.caveat(18)).foregroundStyle(Theme.ink)
                Text("pick a card below or just ask me anything 💬")
                    .font(Theme.font(13, .medium)).foregroundStyle(Theme.dim)
            }
            .padding(.top, 40)
            Spacer(minLength: 24)   // pins the card grid to the bottom of the column
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(starters, id: \.action) { s in
                    Button { app.runFlow(s.action) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.emoji).font(.system(size: 22)).padding(.bottom, 1)
                            Text(s.title).font(Theme.serif(13.5, .heavy)).foregroundStyle(Theme.ink)
                            Text(s.sub).font(Theme.font(11, .medium)).foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(13)
                        .background(
                            LinearGradient(colors: [Color(hex: s.from), Color(hex: s.to)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13)
                        )
                        .background(RoundedRectangle(cornerRadius: 13).fill(Theme.ink).offset(y: 4))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.ink, lineWidth: 2.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
            .padding(.bottom, 14)   // keep the cards' offset ink shadow clear of the input bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }

    // MARK: input

    private var inputBar: some View {
        VStack(spacing: 8) {
            if app.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.action) { chip in
                            Button { app.runFlow(chip.action) } label: {
                                Text(chip.label).font(Theme.font(11.5, .bold)).foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.card))
                                    .background(Capsule().fill(Theme.ink).offset(y: 3))
                                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2).padding(.vertical, 3)
                }
            }
            HStack(spacing: 8) {
                TextField("ask penny anything... e.g. why am i broke?", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.ink)   // explicit: never white-on-cream
                    .tint(Theme.limeD)             // brand-colored caret
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.card))
                    .background(Capsule().fill(Theme.ink).offset(y: 3))
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
                    .onSubmit(sendDraft)
                    .disabled(app.isThinking)
                    .accessibilityIdentifier("chat.input")

                if app.isThinking {
                    // While the model streams, the send button becomes a Stop button so
                    // the user can cut off a runaway or hallucinating answer mid-stream.
                    Button(action: app.cancelGeneration) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.lime))
                            .background(Circle().fill(Theme.ink).offset(y: 3))
                            .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .accessibilityIdentifier("chat.stop")
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(canSend ? Theme.lime : Theme.line))
                            .background(Circle().fill(Theme.ink).offset(y: 3))
                            .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityIdentifier("chat.send")
                }
            }
            .padding(.bottom, 3)
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
    @EnvironmentObject var app: AppModel
    let message: ChatMessage
    /// The most recent message in the transcript — only its reply offers Regenerate.
    var isLast: Bool = false

    /// Brief "Copied ✓" affirmation after the Copy button is tapped.
    @State private var copied = false

    // Tables need room for many columns; prose stays narrow for readability.
    private var maxBubbleWidth: CGFloat {
        if message.role == .user { return 440 }
        return MD.hasTable(message.content) ? 820 : 560
    }

    /// Template `.bb` corners: speech-pointer corner tightened to 5.
    private var bubbleShape: UnevenRoundedRectangle {
        message.role == .user
            ? UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 15,
                                     bottomTrailingRadius: 15, topTrailingRadius: 5)
            : UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 15,
                                     bottomTrailingRadius: 15, topTrailingRadius: 15)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.role == .assistant {
                PennyAvatar(size: 30, mood: message.content.isEmpty ? .thinking : .happy)
                    .padding(.bottom, 5)
            } else {
                Spacer(minLength: 40)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant, let engine = message.engine, !message.content.isEmpty {
                    Text("⚡ \(engine.uppercased()) ENGINE")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.limeD)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.limeS, in: Capsule())
                        .overlay(Capsule().stroke(Theme.limeD, lineWidth: 1.5))
                        // Explicit: this Text otherwise surfaces its string as the
                        // AX *value* with an empty label, which VoiceOver reads
                        // poorly and UI tests can't match by label.
                        .accessibilityLabel("\(engine.uppercased()) ENGINE")
                }
                if !message.content.isEmpty {
                    Group {
                        if message.role == .user {
                            Text(message.content)
                                .font(Theme.font(13, .bold))
                                .foregroundStyle(Theme.ink)
                        } else {
                            ChatMarkdown(text: message.content)   // renders markdown tables as grids
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(bubbleShape.fill(message.role == .user ? Theme.lime : Theme.card))
                    .background(bubbleShape.fill(Theme.ink).offset(y: 3))
                    .overlay(bubbleShape.stroke(Theme.ink, lineWidth: 2))
                    .frame(maxWidth: maxBubbleWidth,
                           alignment: message.role == .user ? .trailing : .leading)
                    // One flat element whose label IS the message text (raw
                    // markdown for assistant replies) — `.combine` produces an
                    // empty label for the ChatMarkdown stack, which UI tests
                    // (and VoiceOver) can't read.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message.content)
                    .accessibilityIdentifier(message.role == .user ? "chat.msg.user" : "chat.msg.assistant")
                }
                // Copy + thumbs-up/down, shown under a finished assistant reply.
                if message.role == .assistant, !message.content.isEmpty {
                    messageActions
                }
            }
            if message.role == .user {
                // trailing bubble; no avatar
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: message actions (copy · like · dislike)

    private var messageActions: some View {
        HStack(spacing: 2) {
            actionButton(icon: copied ? "checkmark" : "doc.on.doc",
                         active: copied, help: copied ? "Copied" : "Copy",
                         id: "chat.msg.copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(message.content, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    copied = false
                }
            }
            // Regenerate only the latest reply (and never mid-stream).
            if isLast, !app.isThinking {
                actionButton(icon: "arrow.clockwise", active: false, help: "Regenerate",
                             id: "chat.msg.regenerate") {
                    app.regenerate()
                }
            }
        }
        .padding(.leading, 2).padding(.top, 1)
    }

    private func actionButton(icon: String, active: Bool, help: String, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Theme.limeD : Theme.dim)
                .frame(width: 26, height: 22)
                .background(active ? Theme.limeS : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Typing indicator (the three-dot bubble)

struct TypingIndicator: View {
    @State private var t = 0.0
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 15,
                               bottomTrailingRadius: 15, topTrailingRadius: 15)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            PennyAvatar(size: 30, mood: .thinking).padding(.bottom, 5)
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.lime)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * abs(sin(t + Double(i) * 0.6)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(shape.fill(Theme.card))
            .background(shape.fill(Theme.ink).offset(y: 3))
            .overlay(shape.stroke(Theme.ink, lineWidth: 2))
            Spacer(minLength: 40)
        }
        .onAppear {
            guard !TestMode.freezeAnimations else { t = .pi / 2; return }
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
