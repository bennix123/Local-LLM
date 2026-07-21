import SwiftUI

/// The centre-column History view — past conversations as hard-shadow cards in
/// the same design language as the rest of the shell. Click a card to reopen
/// that chat; × forgets it. Everything is stored on this Mac only.
struct ChatHistoryView: View {
    @EnvironmentObject var app: AppModel

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if app.history.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .background(Theme.paper)
    }

    // MARK: header (matches the chat header)

    private var header: some View {
        HStack(spacing: 11) {
            PennyAvatar(size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(Theme.serif(17, .heavy)).foregroundStyle(Theme.ink)
                Text("\(app.history.count) past chat\(app.history.count == 1 ? "" : "s") · stored on this Mac")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button { app.centerView = .chat } label: {
                Text("today's chat →")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.limeD)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.limeS, in: Capsule())
                    .overlay(Capsule().stroke(Theme.limeD, lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Back to today's chat")
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    // MARK: list

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(app.history) { session in
                    sessionCard(session)
                }
                if !suggestions.isEmpty {
                    suggestionSection
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: follow-up suggestions from older chats

    /// Follow-up prompts derived from past conversations — one per distinct
    /// topic (the session's first user message), newest first, max four.
    private var suggestions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for session in app.history {
            let topic = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty, seen.insert(topic.lowercased()).inserted else { continue }
            let t = topic.count > 42 ? String(topic.prefix(42)) + "…" : topic
            switch out.count % 3 {
            case 0:  out.append("Recap what we covered about “\(t)”")
            case 1:  out.append("Anything new since we discussed “\(t)”?")
            default: out.append("Go deeper on “\(t)” — what did we miss?")
            }
            if out.count == 4 { break }
        }
        return out
    }

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Theme.line.frame(width: 14, height: 2)
                Text("ASK ME AGAIN").font(Theme.mono(9.5)).foregroundStyle(Theme.dim).kerning(1.3)
                Theme.line.frame(height: 2)
            }
            .padding(.top, 10)
            ForEach(suggestions, id: \.self) { q in
                Button {
                    app.centerView = .chat
                    app.send(q)
                } label: {
                    HStack(spacing: 8) {
                        Text("💭").font(.system(size: 12))
                        Text(q)
                            .font(Theme.font(11.5, .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("ask →").font(Theme.mono(9)).foregroundStyle(Theme.limeD)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hardCard(radius: 11, border: 2, shadow: 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionCard(_ session: ChatSession) -> some View {
        HStack(spacing: 11) {
            Text("💬")
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(Theme.serif(14, .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(Self.dateFmt.string(from: session.date)) · \(session.messages.count) messages")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.dim)
                if let reply = lastReply(session) {
                    Text(reply)
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("open →")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.limeD)
            Button { app.deleteSession(session) } label: {
                Text("×")
                    .font(Theme.font(14, .bold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Forget this chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 13, border: 2, shadow: 4)
        .contentShape(Rectangle())
        .onTapGesture { app.openSession(session) }
    }

    /// One-line preview: Penny's last answer, cleaned of table syntax.
    private func lastReply(_ session: ChatSession) -> String? {
        guard let content = session.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
        else { return nil }
        let line = content
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("|") }
        return line.map { String($0.prefix(90)) }
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            PennyAvatar(size: 72)
            Text("no past chats yet")
                .font(Theme.serif(18, .heavy))
                .foregroundStyle(Theme.ink)
            Text("finish a conversation and hit ✨ New chat —\ni'll keep it safe here, on this Mac.")
                .font(Theme.caveat(15))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
