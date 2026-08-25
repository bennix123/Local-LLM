// ChatViewIOS — the centre of the product, per the mockup: Penny avatar header,
// fun-action buttons (Roast / Splurge / Why broke / Kill subs), bubbles with an
// engine badge on every answer, chips, and the composer. Answers come from the
// real chain: FinanceRouter (exact, instant) → on-device model (advice/roasts).
import SwiftUI

struct ChatViewIOS: View {
    @EnvironmentObject var model: IOSModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            funActions
            messages
            composer
        }
        .background(T.bg)
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [T.lime, T.mint],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("P").font(T.display(24)).foregroundStyle(T.ink)
            }
            .frame(width: 50, height: 50)
            .shadow(color: T.lime.opacity(0.3), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("penny").font(T.display(18, .bold)).foregroundStyle(T.ink)
                Text(model.isThinking ? "thinking…" : "on-device · ready to chat")
                    .font(T.mono(10)).foregroundStyle(T.dim)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
    }

    private var funActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(IOSModel.funActions, id: \.label) { action in
                    Button { model.send(action.prompt) } label: {
                        Text(action.label)
                            .font(T.body(13, .semibold)).foregroundStyle(T.ink)
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(T.card, in: Capsule())
                            .overlay(Capsule().stroke(T.line, lineWidth: 1))
                    }
                    .disabled(model.isThinking)
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 8)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { msg in bubble(msg).id(msg.id) }
                    if model.needsModelDownload && !model.messages.isEmpty {
                        loadModelButton
                    }
                    if model.modelLoading { modelProgress }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
            .onChange(of: model.messages) {
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Ask about your money.")
                .font(T.display(20, .bold)).foregroundStyle(T.ink)
            Text("Totals, categories, merchants, recurring charges — exact figures from the Swift engine. Advice and roasts from the on-device model.")
                .font(T.body(13)).foregroundStyle(T.dim)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40).padding(.horizontal, 24)
    }

    private func bubble(_ msg: IOSChatMsg) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
            Text(msg.text.isEmpty ? "…" : markdownish(msg.text))
                .font(T.body(14))
                .foregroundStyle(T.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(msg.role == .user ? T.lime : T.card,
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(msg.role == .user ? .clear : T.line, lineWidth: 1))
            if let engine = msg.engine {
                Text(engineLabel(engine))
                    .font(T.mono(9, .semibold)).kerning(0.8)
                    .foregroundStyle(T.dim2)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
        .padding(msg.role == .user ? .leading : .trailing, 40)
    }

    private func engineLabel(_ engine: String) -> String {
        switch engine {
        case "swift engine": return "⚡ SWIFT ENGINE · EXACT"
        case "apple": return "🍎 APPLE INTELLIGENCE · ON-DEVICE"
        case "mlx": return "🧠 MLX · ON-DEVICE"
        default: return engine.uppercased()
        }
    }

    private var loadModelButton: some View {
        Button { model.loadModel() } label: {
            Text("Load on-device model (~1.8 GB, once)")
                .font(T.body(13, .semibold)).foregroundStyle(T.limeDeep)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(T.limeSoft, in: Capsule())
        }
    }

    private var modelProgress: some View {
        VStack(spacing: 6) {
            ProgressView(value: model.modelLoadFraction).tint(T.limeDeep)
            Text("\(Int(model.modelLoadFraction * 100))% · downloading weights")
                .font(T.mono(10)).foregroundStyle(T.dim)
        }
        .padding(.horizontal, 30)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask Penny anything…", text: $draft)
                .font(T.body(14))
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(T.card, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(T.line, lineWidth: 1))
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(T.ink)
                    .frame(width: 42, height: 42)
                    .background(T.lime, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(T.bg)
    }

    private func sendDraft() {
        let q = draft
        draft = ""
        model.send(q)
    }

    /// Minimal **bold** support for router answers (AttributedString markdown).
    private func markdownish(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
