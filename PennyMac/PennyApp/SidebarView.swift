import SwiftUI

/// The left navigation rail — SwiftUI port of `components/Sidebar.jsx`.
/// Conversations, quick-action flows, the imported-statement list, an offline
/// toggle, and the "Penny's brain" status block.
struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    var onUpload: () -> Void
    var onSwitchModel: () -> Void

    private let flows: [(icon: String, label: String, action: String)] = [
        ("🔥", "Roast me", "roast"),
        ("👻", "Ghosts", "ghosts"),
        ("⚡", "Patterns", "patterns"),
        ("⛅", "Forecast", "forecast"),
        ("📈", "Compound math", "compound"),
        ("📊", "Reports", "reports"),
        ("💸", "Can I splurge?", "splurge"),
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
            HStack(spacing: 8) {
                PennyAvatar(size: 26)
                PennyWordmark(size: 18)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("conversations") {
                        row(icon: "💬", label: "Today's chat", active: true) { }
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
                            row(icon: docIcon(doc.name),
                                label: doc.name,
                                active: app.selectedDocNames.contains(doc.name)) {
                                app.toggleDoc(doc.name)
                            }
                        }
                        Button(action: onUpload) {
                            HStack(spacing: 6) {
                                if app.isImporting {
                                    ProgressView().controlSize(.small)
                                    Text("Reading \(app.importingName ?? "statement")…")
                                        .lineLimit(1).truncationMode(.middle)
                                } else {
                                    Text("+ upload statement")
                                }
                            }
                            .font(Theme.font(11, .semibold)).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .disabled(app.isImporting)
                    }
                }
                .padding(.horizontal, 12)
            }

            offlinePanel
            brainPanel
        }
        .frame(width: 244)
        .frame(maxHeight: .infinity)
        .background(Theme.bg2)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
    }

    // MARK: pieces

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.font(10, .bold)).foregroundStyle(Theme.dim).textCase(.uppercase)
                .padding(.leading, 6).padding(.bottom, 2)
            content()
        }
    }

    private func row(icon: String, label: String, active: Bool = false,
                     badge: Int? = nil, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 9) {
                Text(icon).font(.system(size: 13)).frame(width: 18)
                Text(label).font(Theme.font(12.5, active ? .bold : .medium))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)").font(Theme.font(9, .bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.coralS, in: Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(active ? Theme.limeS.opacity(0.7) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(active ? Theme.limeD.opacity(0.5) : Color.clear, lineWidth: 1)
            )
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

    private var offlinePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(app.offlineOnly ? Theme.limeD : Theme.sun).frame(width: 7, height: 7)
                    Text(app.offlineOnly ? "Offline mode" : "Online when needed")
                        .font(Theme.font(11, .bold)).foregroundStyle(Theme.ink)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !app.offlineOnly },
                                         set: { app.offlineOnly = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.limeD)
            }
            Text(app.offlineOnly
                 ? "Penny is fully offline. She'll never reach the internet."
                 : "Penny stays local, but may fetch public numbers (like prices) when a question needs them. Your data never goes out.")
                .font(Theme.font(10)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.card)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private var brainPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PENNY'S BRAIN").font(Theme.font(9, .bold)).foregroundStyle(Theme.dim)
            Button(action: onSwitchModel) {
                HStack {
                    Text(app.modelDisplayName.uppercased())
                        .font(Theme.font(12, .heavy)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("switch").font(Theme.font(9, .semibold)).foregroundStyle(Theme.limeD)
                }
            }
            .buttonStyle(.plain)
            stat("Statements", "\(app.docs.count)")
            stat("Transactions", "\(app.transactionCount)")
            stat("Data sent out", "0 bytes", valueColor: Theme.limeD)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tint)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private func stat(_ k: String, _ v: String, valueColor: Color = Theme.ink) -> some View {
        HStack {
            Text(k).font(Theme.font(10)).foregroundStyle(Theme.dim)
            Spacer()
            Text(v).font(Theme.font(10, .bold)).foregroundStyle(valueColor)
        }
    }
}
