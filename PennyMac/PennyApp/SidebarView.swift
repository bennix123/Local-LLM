import SwiftUI

/// The left navigation rail — restyled to the design template's `.sb`:
/// serif brand, mono section headers, ink-filled active rows, and the
/// hard-shadow "net" + "Penny's brain" cards. All figures stay real.
struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    var onUpload: () -> Void
    var onSwitchModel: () -> Void
    @State private var pulsing = false
    @State private var confirmingWipe = false
    @State private var editingAPIKey = false
    @State private var apiKeyDraft = ""

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
                wipeRow
            }
            .padding(12)
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Theme.bg2)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
        .onAppear {
            if !TestMode.freezeAnimations { pulsing = true }
            app.refreshDownloadedModels()   // keeps the 8B-upgrade nudge honest
        }
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

    /// `.net` — the privacy card. Reflects reality: fully offline until an AI
    /// fallback (opt-in, needs a key) actually sends data, then it says so
    /// honestly. Statements/balances never leave regardless — only merchant
    /// descriptors are ever sent, and only for categorization.
    private var netPanel: some View {
        let offline = app.bytesSentOut == 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(offline ? Theme.limeD : Theme.coral).frame(width: 6, height: 6)
                Text(offline ? "FULLY OFFLINE" : "CLOUD AI USED")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(offline ? Theme.limeD : Theme.coral)
                    .kerning(0.8)
            }
            Text(MD.inline(offline
                ? "Penny is **fully offline**. Your statements and questions never leave this Mac."
                : "Merchant names (and scanned-PDF text, if OCR was needed) were sent to Claude (**\(app.dataSentLabel)**). Your statements, balances and questions stay on this Mac."))
                .font(Theme.font(10.5, .medium)).foregroundStyle(Theme.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: offline ? Color(hex: 0xeefbe0) : Color(hex: 0xfdeee9), radius: 13, border: 2,
                  borderColor: offline ? Theme.limeD : Theme.coral, shadow: 3)
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
            stat("Data sent out", app.dataSentLabel,
                 valueColor: app.bytesSentOut == 0 ? Theme.limeD : Theme.coral)
            apiKeyRow
            if app.recheckableMerchantCount > 0 { categorizeButton }
            if app.showUpgradeNudge { upgradeNudge }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 13, border: 2, shadow: 3)
    }

    /// Claude API key management — categories come from the API ONLY, so the
    /// key is front and center: keyless shows an add-key affordance that
    /// reveals a paste field; keyed shows the connected state with a remove
    /// affordance. The key lives in the Keychain (see `APIKeyStore`).
    @ViewBuilder private var apiKeyRow: some View {
        if app.claudeAPIKey != nil {
            HStack(spacing: 6) {
                Text("Claude API").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                Text("connected").font(Theme.mono(9)).foregroundStyle(Theme.limeD)
                Button { app.clearClaudeAPIKey() } label: {
                    Text("×").font(Theme.font(11, .bold)).foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("brain.apiKey.remove")
            }
            .padding(.top, 1)
        } else if editingAPIKey {
            HStack(spacing: 5) {
                SecureField("sk-ant-…", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(9))
                    .onSubmit(saveAPIKey)
                    .accessibilityIdentifier("brain.apiKey.field")
                Button(action: saveAPIKey) {
                    Text("save").font(Theme.mono(8.5)).foregroundStyle(Theme.limeD)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("brain.apiKey.save")
            }
            .padding(.top, 2)
        } else if PennyBackend.isConfigured {
            // No personal key, but the hosted proxy categorizes for everyone — show
            // a calm connected state, not the "add a key" nag. Tapping still lets a
            // user supply their own key to bypass the proxy.
            HStack(spacing: 6) {
                Text("Claude API").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                Text("connected").font(Theme.mono(9)).foregroundStyle(Theme.limeD)
                Button { editingAPIKey = true } label: {
                    Text("use own key").font(Theme.mono(8.5)).foregroundStyle(Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 1)
        } else {
            Button { editingAPIKey = true } label: {
                Text(MD.inline("🔑 **add Claude API key** — categories need it"))
                    .font(Theme.font(9.5, .semibold))
                    .foregroundStyle(Theme.coral)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("brain.apiKey.add")
            .padding(.top, 3)
        }
    }

    private func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        app.setClaudeAPIKey(key)
        apiKeyDraft = ""
        editingAPIKey = false
    }

    /// Manual trigger for the API categorization pass: asks Claude to
    /// categorize the unresolved merchants AND to re-check rows an earlier
    /// pass placed — the model may coin new categories beyond the canonical
    /// list. Categories come from the API only; without a key this surfaces
    /// the add-key toast.
    private var categorizeButton: some View {
        Button { app.refineCategoriesForLoadedStatements(manual: true) } label: {
            HStack(spacing: 6) {
                Text(app.isRecategorizing
                     ? MD.inline("categorizing…")
                     : app.uncategorizedMerchantCount > 0
                        ? MD.inline("✨ **categorize \(app.uncategorizedMerchantCount)** with AI")
                        : MD.inline("✨ recheck categories with AI"))
                    .font(Theme.font(9.5, .semibold))
                    .foregroundStyle(Theme.limeD)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.isRecategorizing)
        .accessibilityIdentifier("brain.categorize")
        .padding(.top, 3)
    }

    /// One-line hint for 16 GB+ Macs still on the 3B slice: the 8B model fits —
    /// tapping it opens the model picker; × dismisses it for good.
    private var upgradeNudge: some View {
        HStack(spacing: 6) {
            Button(action: onSwitchModel) {
                Text(MD.inline("✨ **8B model** available for this Mac — switch"))
                    .font(Theme.font(9.5, .semibold))
                    .foregroundStyle(Theme.limeD)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("brain.upgradeNudge")
            Spacer(minLength: 4)
            Button { app.upgradeNudgeDismissed = true } label: {
                Text("×").font(Theme.font(11, .bold)).foregroundStyle(Theme.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("brain.upgradeNudge.dismiss")
        }
        .padding(.top, 3)
    }

    /// Destructive "wipe all data" affordance — deletes the persisted
    /// statements + chat history and resets the session, after a confirmation.
    private var wipeRow: some View {
        Button { confirmingWipe = true } label: {
            HStack(spacing: 6) {
                Text("🗑").font(.system(size: 10))
                Text("Wipe all data").font(Theme.font(10.5, .bold)).foregroundStyle(Theme.coral)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hardCard(fill: Theme.coralS, radius: 11, border: 2,
                      borderColor: Theme.coral, shadow: 2, shadowColor: Theme.coral)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.wipe")
        .confirmationDialog("Wipe all data?", isPresented: $confirmingWipe, titleVisibility: .visible) {
            Button("Wipe statements & chats", role: .destructive) { app.wipeAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every imported statement and chat from this Mac. This can't be undone.")
        }
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
