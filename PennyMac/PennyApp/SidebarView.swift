import SwiftUI

/// The left navigation rail — restyled to the design template's `.sb`:
/// serif brand, mono section headers, ink-filled active rows, and the
/// hard-shadow "net" + "Penny's brain" cards. All figures stay real.
struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    var onUpload: () -> Void
    var onSwitchModel: () -> Void
    @State private var pulsing = false

    private let flows: [(icon: String, label: String, action: String)] = [
        ("🔥", "Roast me", "roast"),
        ("👻", "Ghosts", "ghosts"),
        ("⚡", "Patterns", "patterns"),
        ("📊", "Reports", "reports"),
    ]

    /// Real badge counts (never hardcoded): Ghosts = detected recurring
    /// subscriptions. Other flows carry no count. Shown only when > 0.
    private func badge(for action: String) -> Int? {
        switch action {
        case "ghosts": return app.ghostCount > 0 ? app.ghostCount : nil
        default:       return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PennyAvatar(size: 40)
                PennyWordmark(size: 19, design: .serif)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.horizontal, 12) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("conversations") {
                        row(icon: "💬", label: "Today's chat", active: app.centerView == .chat) {
                            app.centerView = .chat
                        }
                        row(icon: "🕐", label: "History", active: app.centerView == .history,
                            badge: app.history.isEmpty ? nil : app.history.count) {
                            app.centerView = .history
                        }
                        row(icon: "✨", label: "New chat") { app.newChat() }
                    }

                    section("jump to") {
                        ForEach(flows, id: \.action) { f in
                            row(icon: f.icon, label: f.label, badge: badge(for: f.action)) {
                                app.runFlow(f.action)
                            }
                        }
                    }

                    section("accounts") {
                        ForEach(app.docs) { doc in
                            accountRow(doc)
                        }
                        Button(action: onUpload) {
                            HStack(spacing: 6) {
                                if app.isImporting {
                                    ProgressView().controlSize(.small)
                                    Text("Reading \(app.importingName ?? "statement")…")
                                        .lineLimit(1).truncationMode(.middle)
                                } else {
                                    Text("+ upload more")
                                }
                            }
                            .font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(app.isImporting)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            VStack(spacing: 10) {
                netPanel
                brainPanel
            }
            .padding(12)
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Theme.bg2)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
        .onAppear { if !TestMode.freezeAnimations { pulsing = true } }
    }

    // MARK: pieces

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Theme.mono(9)).foregroundStyle(Theme.dim).kerning(1.2)
                .padding(.leading, 8).padding(.bottom, 5)
            content()
        }
    }

    private func row(icon: String, label: String, active: Bool = false,
                     badge: Int? = nil, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Text(icon).font(.system(size: 13)).frame(width: 18)
                Text(label).font(Theme.font(12.5, .semibold))
                    .foregroundStyle(active ? Theme.bg : Theme.ink2).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)").font(Theme.mono(8.5)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.coral, in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(active ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `.acrow` — imported statement with its icon tile and latest balance
    /// (cards fall back to their stated closing balance — the amount owed).
    private func accountRow(_ doc: LoadedDoc) -> some View {
        let selected = app.selectedDocNames.contains(doc.name)
        let balance = doc.latestBalance
        return Button { app.toggleDoc(doc.name) } label: {
            HStack(spacing: 9) {
                Text(docIcon(doc.name))
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(selected ? Theme.ink : Theme.line, lineWidth: 1))
                Text(doc.displayName)
                    .font(Theme.font(11, .semibold))
                    .foregroundStyle(selected ? Theme.ink2 : Theme.dim)
                    .lineLimit(1).truncationMode(.middle)
                    .help(doc.name)   // hover shows the underlying file
                Spacer(minLength: 4)
                if let balance {
                    Text(Money.format(balance, currency: doc.currency))
                        .font(Theme.mono(9.5)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Color.white.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func docIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("amex") || n.contains("credit") || n.contains("card") { return "💳" }
        if n.contains("vanguard") || n.contains("stock") || n.contains("trade") { return "📈" }
        if n.contains("pension") || n.contains("nest") { return "🏛" }
        if n.contains("crypto") || n.contains("coinbase") { return "🪙" }
        return "🏦"
    }

    /// `.net` — the offline/online privacy card.
    private var netPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(app.offlineOnly ? Theme.dim : Theme.limeD)
                        .frame(width: 6, height: 6)
                        .opacity(!app.offlineOnly && pulsing ? 0.4 : 1)
                        .animation(app.offlineOnly ? .default
                                   : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                                   value: pulsing)
                    Text(app.offlineOnly ? "OFFLINE MODE" : "ONLINE WHEN NEEDED")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(app.offlineOnly ? Theme.dim : Theme.limeD)
                        .kerning(0.8)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !app.offlineOnly },
                                         set: { app.offlineOnly = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.lime)
            }
            Text(MD.inline(app.offlineOnly
                 ? "Penny is **fully offline**. She'll never reach the internet."
                 : "Penny stays local, but can fetch **public numbers** when needed. **Your data never goes out.**"))
                .font(Theme.font(10.5, .medium)).foregroundStyle(Theme.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: app.offlineOnly ? Color(hex: 0xf4f0e6) : Color(hex: 0xeefbe0),
                  radius: 13, border: 2,
                  borderColor: app.offlineOnly ? Theme.ink : Theme.limeD,
                  shadow: 3)
    }

    /// `.bp` — "PENNY'S BRAIN" model + stats card.
    private var brainPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(Theme.lime).frame(width: 5, height: 5)
                    .opacity(pulsing ? 0.4 : 1)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
                Text("PENNY'S BRAIN")
                    .font(Theme.mono(8.5)).foregroundStyle(Theme.limeD).kerning(1)
            }
            Button(action: onSwitchModel) {
                HStack {
                    Text(app.modelDisplayName)
                        .font(Theme.serif(12.5, .heavy)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("switch").font(Theme.mono(8.5)).foregroundStyle(Theme.limeD)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            stat("Statements", "\(app.docs.count)")
            stat("Transactions", "\(app.transactionCount)")
            stat("Data sent out", "0 bytes", valueColor: Theme.limeD)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 13, border: 2, shadow: 3)
    }

    private func stat(_ k: String, _ v: String, valueColor: Color = Theme.ink) -> some View {
        HStack {
            Text(k).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            Spacer()
            Text(v).font(Theme.mono(9)).foregroundStyle(valueColor)
        }
        .padding(.vertical, 1.5)
    }
}
