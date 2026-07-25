import SwiftUI
import UniformTypeIdentifiers
import PennyTxnStore

// MARK: - Account-kind catalog (the template's ACCTS table + S4 groups)

struct AccountKind: Identifiable, Equatable {
    let id: String
    let icon: String
    let name: String
    let cardSub: String       // S4 grid-card subtitle
    let uploadSub: String     // S5 subheading under the account name
    let exportSteps: [String] // "How to export" steps (**bold** markdown)
    let demoFile: String      // stand-in file when the user skips uploads
    let demoMeta: String
    var comingSoon: Bool = false   // greyed-out, non-selectable teaser card

    static let sections: [(title: String, kinds: [AccountKind])] = [
        ("SPENDING", [
            AccountKind(id: "current", icon: "🏦", name: "Current account", cardSub: "Day-to-day",
                        uploadSub: "drop a statement file · CSV / PDF",
                        exportSteps: ["Open your bank app or website",
                                      "Find **Statements** or **Download transactions**",
                                      "Pick **last 12 months**, format **CSV** (PDF also works)",
                                      "Save to your Mac, then drag here"],
                        demoFile: "monzo_oct.csv", demoMeta: "14.2 KB · 1,142 rows"),
            AccountKind(id: "credit", icon: "💳", name: "Credit card", cardSub: "Visa / Mastercard / Amex",
                        uploadSub: "drop a statement file · CSV / PDF",
                        exportSteps: ["Log into your card issuer (Amex, Barclaycard, etc.)",
                                      "Go to **Statements & Activity**",
                                      "Select **last 12 months**, choose **CSV or PDF**",
                                      "Drag the file here"],
                        demoFile: "amex_2024.csv", demoMeta: "8.4 KB · 316 rows"),
        ]),
        ("SAVINGS", [
            AccountKind(id: "savings", icon: "🐖", name: "Savings account", cardSub: "Easy-access or notice",
                        uploadSub: "drop a statement file",
                        exportSteps: ["Open your savings bank", "Find **Statements**",
                                      "Pick **last 12 months**", "Drag CSV or PDF here"],
                        demoFile: "savings_2024.csv", demoMeta: "3.2 KB · 24 rows"),
        ]),
        ("INVESTMENTS", [
            AccountKind(id: "stocks", icon: "📈", name: "Stocks & shares", cardSub: "Vanguard, T212, HL",
                        uploadSub: "drop your broker report · PDF / CSV",
                        exportSteps: ["Log into broker (Vanguard, T212, HL)", "Find **Account history**",
                                      "Export **12 months** as CSV", "Drag here — I'll read trades & dividends"],
                        demoFile: "t212_report.csv", demoMeta: "6.7 KB · 89 trades", comingSoon: true),
            AccountKind(id: "crypto", icon: "🪙", name: "Crypto wallet", cardSub: "Coinbase, Kraken",
                        uploadSub: "drop an exchange CSV",
                        exportSteps: ["Log into exchange (Coinbase, Kraken)", "Go to **Reports**",
                                      "Export transactions as CSV", "Drag here"],
                        demoFile: "coinbase.csv", demoMeta: "4.1 KB · 47 txns", comingSoon: true),
            AccountKind(id: "pension", icon: "🏛", name: "Pension", cardSub: "Nest, PenFold, workplace",
                        uploadSub: "drop annual statement · PDF",
                        exportSteps: ["Log into your pension provider", "Download **most recent statement**",
                                      "PDF is fine", "Drag here"],
                        demoFile: "pension_2024.pdf", demoMeta: "180 KB · PDF 12 pages", comingSoon: true),
            AccountKind(id: "property", icon: "🏠", name: "Property / mortgage", cardSub: "Statement-based",
                        uploadSub: "drop mortgage statement · PDF",
                        exportSteps: ["Log into your mortgage provider", "Download annual statement",
                                      "Upload PDF — I track principal & equity"],
                        demoFile: "mortgage.pdf", demoMeta: "96 KB · PDF 6 pages", comingSoon: true),
        ]),
        ("OTHER", [
            AccountKind(id: "business", icon: "💼", name: "Business account", cardSub: "Ltd co or sole trader",
                        uploadSub: "drop a statement file",
                        exportSteps: ["Log into business bank", "Find **Statements**",
                                      "Pick **12 months** CSV", "Drag here"],
                        demoFile: "tide_business.csv", demoMeta: "22.4 KB · 1,847 rows", comingSoon: true),
            AccountKind(id: "other", icon: "+", name: "Something else", cardSub: "Any financial file",
                        uploadSub: "drop any financial file · CSV / PDF",
                        exportSteps: ["Export from wherever the money lives", "**CSV or PDF** works",
                                      "Drag the file here"],
                        demoFile: "statement.csv", demoMeta: "~15 KB · ~1,000 rows", comingSoon: true),
        ]),
    ]

    static let all: [AccountKind] = sections.flatMap(\.kinds)
    static func byID(_ id: String) -> AccountKind { all.first { $0.id == id } ?? all[0] }
}

/// File-type chip for a statement row ("PDF" / "CSV"), from the filename —
/// imports are no longer PDF-only, so the meta line must not hardcode "PDF".
private func statementTypeLabel(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.uppercased()
    return ext.isEmpty ? "FILE" : ext
}

// MARK: - S2 NAME (.s2)

struct NameStep: View {
    @EnvironmentObject var app: AppModel
    @State private var bounced = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg, Color(hex: 0xfef3c7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 0) {
                left.frame(maxWidth: .infinity, maxHeight: .infinity)
                right.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("First — what should").font(Theme.serif(42)).kerning(-1.3).foregroundStyle(Theme.ink)
                HStack(spacing: 0) {
                    Text("I ").font(Theme.serif(42)).kerning(-1.3).foregroundStyle(Theme.ink)
                    Text("call you?").font(Theme.serif(42)).kerning(-1.3).foregroundStyle(Theme.limeD)
                }
            }
            Text("I'll use your first name when I talk to you. Doesn't need to be your legal one.")
                .font(Theme.font(14.5))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(4)
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.top, 14)

            TextField("Alex", text: $app.userName)
                .textFieldStyle(.plain)
                .font(Theme.serif(26, .heavy))
                .foregroundStyle(Theme.ink)
                .tint(Theme.limeD)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 420)
                .hardCard(radius: 17, border: 3, shadow: 5)
                .padding(.top, 26)
                .onSubmit { app.goToStep(3) }

            Text("📌 stays on this Mac · never shared")
                .font(Theme.caveat(15))
                .foregroundStyle(Theme.dim)
                .padding(.top, 12)

            HStack(spacing: 11) {
                SkipButton("← back") { app.goToStep(1) }
                Button { app.goToStep(3) } label: {
                    Text("Nice to meet you →")
                        .font(Theme.font(14.5, .bold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(LimeButtonStyle())
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var right: some View {
        VStack(spacing: 22) {
            SpeechBubble("eee, a new friend! 🥹\nwhat's your name?")
            PennyAvatar(size: 130)
                .scaleEffect(bounced ? 1 : 0.8)
                .animation(.spring(response: 0.45, dampingFraction: 0.5), value: bounced)
        }
        .padding(40)
        .onAppear { bounced = true }
    }
}

/// `.sp` — white speech bubble with an ink outline, hard shadow and a tail.
struct SpeechBubble: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.caveat(18))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .frame(maxWidth: 230)
            .hardCard(radius: 17, border: 2.5, shadow: 4)
            .overlay(alignment: .bottom) {
                ZStack {
                    BubbleTail().fill(Theme.ink).frame(width: 18, height: 12).offset(y: 12)
                    BubbleTail().fill(.white).frame(width: 12, height: 8).offset(y: 9)
                }
            }
            .padding(.bottom, 12)
    }
}

struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A horizontal dashed rule (the template's `border-top:1px dashed var(--line)`).
struct DashedRule: View {
    var color: Color = Theme.line
    var body: some View {
        HLine()
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }
}

struct HLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

// MARK: - S3 HOW IT WORKS (.s3)

struct HowItWorksStep: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                PennyAvatar(size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    (Text("How this ").foregroundColor(Theme.ink)
                     + Text("works").foregroundColor(Theme.limeD)
                     + Text(", in four steps").foregroundColor(Theme.ink))
                        .font(Theme.serif(30, .heavy))
                        .kerning(-0.9)
                    Text("No bank logins. No passwords shared. No data leaving your Mac. Just drop files in.")
                        .font(Theme.font(13.5, .medium))
                        .foregroundStyle(Theme.dim)
                }
            }
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 13) {
                stepCard(1, "⬇️", "Download the AI model",
                         "One-time download of **\(app.modelDisplayName)**, sized to fit this Mac's RAM. No internet needed after that.",
                         time: "~3 MINUTES")
                stepCard(2, "📥", "Drop in your files",
                         "**CSV or PDF.** Export from your bank or investment app, drag into Penny.",
                         time: "~3 MINUTES")
                stepCard(3, "🧠", "I read everything locally",
                         "**\(app.modelDisplayName)** on your Mac's chip categorises, finds patterns, spots subs.",
                         time: "~30 SECONDS")
                stepCard(4, "🔒", "Stays on this Mac",
                         "Kept in this app's sandbox — nothing syncs, nothing uploads. Wipe anytime.",
                         time: "FOREVER LOCAL", priv: true)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 16)

            DashedRule()
            HStack {
                HStack(spacing: 10) {
                    PennyAvatar(size: 30)
                    Text("You re-drop fresh files when you want me to see the latest. Once a month is plenty.")
                        .font(Theme.caveat(14.5))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer()
                HStack(spacing: 10) {
                    SkipButton("← back") { app.goToStep(2) }
                    Button { app.goToStep(4) } label: {
                        Text("Got it, let's go →")
                            .font(Theme.font(14.5, .bold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(LimeButtonStyle())
                }
            }
            .padding(.top, 11)
        }
        .padding(.top, 32)
        .padding(.horizontal, 60)
        .padding(.bottom, 20)
        .background(Theme.bg)
    }

    private func stepCard(_ n: Int, _ emoji: String, _ title: String, _ body: String,
                          time: String, priv: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(Theme.serif(40)).foregroundStyle(Theme.limeD)
            Text(emoji).font(.system(size: 28)).padding(.top, 4).padding(.bottom, 10)
            Text(title).font(Theme.serif(15.5, .heavy)).foregroundStyle(Theme.ink)
                .lineSpacing(1).padding(.bottom, 6)
            Text(MD.inline(body))
                .font(Theme.font(12))
                .foregroundStyle(Theme.dim)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            DashedRule()
            Text(priv ? "🔒 \(time)" : time)
                .font(Theme.mono(8.5))
                .foregroundStyle(Theme.limeD)
                .kerning(1)
                .padding(.top, 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hardCard(radius: 17, border: 2.5, shadow: 6)
    }
}

// MARK: - S4 ACCOUNTS (.s4)

struct AccountsStep: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            picker
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
            rail
                .frame(width: 340)
        }
        .background(Theme.bg)
    }

    // left — scrolling account-type grid

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                (Text("What should I ").foregroundColor(Theme.ink)
                 + Text("track").foregroundColor(Theme.limeD)
                 + Text("\nfor you?").foregroundColor(Theme.ink))
                    .font(Theme.serif(30, .heavy))
                    .kerning(-0.9)
                    .lineSpacing(2)
                Text("Pick everything you want in your money picture. Add/remove anytime.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 5)
                    .padding(.bottom, 16)

                ForEach(AccountKind.sections, id: \.title) { section in
                    sectionRule(section.title)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                              spacing: 8) {
                        ForEach(section.kinds) { kind in
                            accountCard(kind)
                        }
                    }
                }
                Color.clear.frame(height: 14)
            }
            .padding(.top, 30)
            .padding(.horizontal, 44)
            .padding(.bottom, 18)
        }
    }

    private func sectionRule(_ title: String) -> some View {
        HStack(spacing: 8) {
            Theme.line.frame(width: 14, height: 2)
            Text(title).font(Theme.mono(9.5)).foregroundStyle(Theme.dim).kerning(1.3)
            Theme.line.frame(height: 2)
        }
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private func accountCard(_ kind: AccountKind) -> some View {
        let selected = app.selectedAccountKinds.contains(kind.id)
        return Button {
            if selected {
                app.selectedAccountKinds.removeAll { $0 == kind.id }
            } else {
                app.selectedAccountKinds.append(kind.id)
                // keep catalog order so the upload tabs read naturally
                app.selectedAccountKinds.sort { a, b in
                    (AccountKind.all.firstIndex { $0.id == a } ?? 0)
                        < (AccountKind.all.firstIndex { $0.id == b } ?? 0)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(kind.icon)
                    .font(.system(size: 16))
                    .frame(width: 34, height: 34)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name).font(Theme.font(13, .bold)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(kind.cardSub).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(kind.comingSoon ? 0.45 : 1)
            .hardCard(fill: selected ? Color(hex: 0xf6fce0) : Theme.card,
                      radius: 11, border: 2,
                      borderColor: kind.comingSoon ? Theme.line : (selected ? Theme.limeD : Theme.ink),
                      shadow: kind.comingSoon ? 0 : 4)
            .overlay(alignment: .topTrailing) {
                if kind.comingSoon {
                    Text("COMING SOON")
                        .font(Theme.mono(7.5, .bold))
                        .kerning(0.8)
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.tint))
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                        .padding(7)
                } else if selected {
                    Text("✓")
                        .font(Theme.font(10, .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 16, height: 16)
                        .background(Theme.lime, in: Circle())
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(kind.comingSoon)
    }

    // right — "What I read" info rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                PennyAvatar(size: 46)
                Text("What I read").font(Theme.serif(18, .heavy)).foregroundStyle(Theme.ink)
            }
            .padding(.bottom, 13)

            infoCard("File formats I understand:", [
                "**CSV** — most common, fastest",
                "**PDF** — statements, broker reports",
            ])
            .padding(.bottom, 10)

            infoCard("What stays private:", [
                "Files **never upload**",
                "Processed on your Mac's chip",
                "Encrypted at rest locally",
                "You can wipe everything anytime",
            ], fill: Theme.limeS, border: Theme.limeD)
            .padding(.bottom, 10)

            Text(MD.inline("💡 **Pro tip:** Drop in 12 months of history first time."))
                .font(Theme.mono(9.5, .semibold))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(3)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )

            Spacer(minLength: 16)

            (Text("\(app.selectedAccountKinds.count)").foregroundColor(Theme.limeD)
             + Text(" accounts selected").foregroundColor(Theme.dim))
                .font(Theme.mono(10.5))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 7)
            Button {
                app.uploadKindIndex = 0
                app.goToStep(5)
            } label: {
                Text("Continue to upload →")
                    .font(Theme.font(14.5, .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LimeButtonStyle())
            .disabled(app.selectedAccountKinds.isEmpty)
            .opacity(app.selectedAccountKinds.isEmpty ? 0.4 : 1)
            SkipButton("← back") { app.goToStep(3) }
                .frame(maxWidth: .infinity)
                .padding(.top, 7)
        }
        .padding(28)
        .background(Theme.bg2)
    }

    private func infoCard(_ title: String, _ items: [String],
                          fill: Color = .white, border: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.caveat(15)).foregroundStyle(Theme.ink)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Text("→").font(Theme.font(11.5, .heavy)).foregroundStyle(Theme.limeD)
                    Text(MD.inline(item))
                        .font(Theme.font(11.5, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(3)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: fill, radius: 13, border: 2, borderColor: border, shadow: 4)
    }
}

// MARK: - S5 UPLOAD (.s5)

struct UploadStep: View {
    @EnvironmentObject var app: AppModel
    @State private var showImporter = false
    @State private var dropHover = false

    private var kinds: [AccountKind] { app.selectedAccountKinds.map(AccountKind.byID) }
    private var current: AccountKind { AccountKind.byID(app.currentUploadKind ?? "current") }
    private var currentUploads: [LoadedDoc] { app.uploads(for: current.id) }

    var body: some View {
        HStack(spacing: 0) {
            accountRail
                .frame(width: 280)
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
            uploadPane
                .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf, .commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { app.importPDF(from: url, kind: current.id) }
            }
        }
    }

    // left — per-account progress tabs

    private var accountRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your accounts").font(Theme.serif(18, .heavy)).foregroundStyle(Theme.ink)
            Text("Drop in files for each. No rush — finish in your own time.")
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .padding(.top, 3)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(kinds.enumerated()), id: \.element.id) { i, kind in
                        accountTab(kind, index: i)
                    }
                }
            }

            Spacer(minLength: 12)
            DashedRule()
            Text("Penny remembers progress — close anytime.")
                .font(Theme.caveat(13))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 12)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 22)
        .background(Theme.bg2)
    }

    private func accountTab(_ kind: AccountKind, index: Int) -> some View {
        let files = app.uploads(for: kind.id)
        let done = !files.isEmpty
        let active = index == app.uploadKindIndex
        return Button {
            app.uploadKindIndex = index
        } label: {
            HStack(spacing: 9) {
                Text(kind.icon)
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .background(Theme.tint, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.name).font(Theme.font(12, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(done ? "\(files.count) FILE\(files.count > 1 ? "S" : "")"
                         : active ? "CURRENT" : "WAITING")
                        .font(Theme.mono(8))
                        .foregroundStyle(done ? Theme.limeD : Theme.dim)
                }
                Spacer(minLength: 0)
                if done {
                    Text("✓")
                        .font(Theme.font(10, .heavy))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 16, height: 16)
                        .background(Theme.lime, in: Circle())
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hardCard(fill: done ? Color(hex: 0xbbf7d0) : active ? Color(hex: 0xf6fce0) : .white,
                      radius: 10, border: 2,
                      borderColor: active ? Theme.limeD : Theme.ink,
                      shadow: 3,
                      shadowColor: active ? Theme.limeD : Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // right — drop zone + files + export help

    private var uploadPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(current.name)
                    .font(Theme.serif(26, .heavy))
                    .kerning(-0.5)
                    .foregroundStyle(Theme.limeD)
                Text(current.uploadSub.uppercased())
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.dim)
                    .kerning(1)
                    .padding(.top, 5)
                    .padding(.bottom, 18)

                dropZone
                    .padding(.bottom, 14)

                if !currentUploads.isEmpty {
                    Text("FILES READY")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.dim)
                        .kerning(1.2)
                        .padding(.bottom, 7)
                    VStack(spacing: 6) {
                        ForEach(currentUploads) { doc in
                            fileCard(doc)
                        }
                    }
                    .padding(.bottom, 14)
                }

                exportHelp
                    .padding(.bottom, 12)

                DashedRule()
                HStack {
                    SkipButton("← back") { app.goToStep(4) }
                    Spacer()
                    HStack(spacing: 9) {
                        Button { app.goToStep(6) } label: {
                            Text("Skip — show demo")
                                .font(Theme.font(12.5, .semibold))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !currentUploads.isEmpty {
                            Button { nextAccount() } label: {
                                Text("Next →")
                                    .font(Theme.font(14.5, .bold))
                                    .foregroundStyle(Theme.ink)
                            }
                            .buttonStyle(LimeButtonStyle())
                        }
                    }
                }
                .padding(.top, 11)
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 44)
        }
    }

    private var dropZone: some View {
        Button { showImporter = true } label: {
            VStack(spacing: 7) {
                if app.isImporting {
                    ProgressView().controlSize(.large)
                    Text("Reading \(app.importingName ?? "file")…")
                        .font(Theme.serif(18, .heavy)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("📥").font(.system(size: 38))
                    Text("Drag files here").font(Theme.serif(18, .heavy)).foregroundStyle(Theme.ink)
                    Text(MD.inline("Or click to browse. **I process them locally — never uploaded.**"))
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 5) {
                        ForEach([".CSV", ".PDF"], id: \.self) { fmt in
                            Text(fmt)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 17).fill(dropHover ? Theme.limeS : .white))
            .background(RoundedRectangle(cornerRadius: 17).fill(Theme.ink).offset(y: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.isImporting)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropHover) { providers in
            let kind = current.id
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url {
                        Task { @MainActor in app.importPDF(from: url, kind: kind) }
                    }
                }
            }
            return true
        }
    }

    private func fileCard(_ doc: LoadedDoc) -> some View {
        HStack(spacing: 9) {
            Text("📄")
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name).font(Theme.font(12, .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(doc.rows.count) rows · \(statementTypeLabel(doc.name))")
                    .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 6)
            Text("READY ✓")
                .font(Theme.mono(8.5, .heavy))
                .foregroundStyle(Theme.limeD)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.limeS, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.limeD, lineWidth: 1.5))
            Button { app.removeDoc(named: doc.name) } label: {
                Text("×").font(Theme.font(13, .bold)).foregroundStyle(Theme.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: Color(hex: 0xdcfce7), radius: 10, border: 2, shadow: 3)
    }

    private var exportHelp: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("💡 How to export").font(Theme.serif(13.5, .heavy)).foregroundStyle(Theme.ink)
            ForEach(Array(current.exportSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(i + 1)")
                        .font(Theme.mono(9.5, .heavy))
                        .foregroundStyle(Theme.limeD)
                        .frame(width: 19, height: 19)
                        .background(.white, in: Circle())
                        .overlay(Circle().stroke(Theme.limeD, lineWidth: 1.5))
                    Text(MD.inline(step))
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(3)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: Theme.tint, radius: 13, border: 2, shadow: 4)
    }

    /// Template `nextAccount()`: jump to the next account with no files, or move on.
    private func nextAccount() {
        for (i, kind) in kinds.enumerated() where i != app.uploadKindIndex {
            if app.uploads(for: kind.id).isEmpty {
                app.uploadKindIndex = i
                return
            }
        }
        app.goToStep(6)
    }
}

// MARK: - S6 PROCESSING (.s6)

/// One row of the live-feed panel.
private struct FeedTxn: Identifiable {
    let id = UUID()
    let icon: String
    let name: String
    let meta: String
    let chip: String
    let chipColor: Color
    let amount: String
    let credit: Bool
}

struct ProcessingStep: View {
    @EnvironmentObject var app: AppModel
    @State private var progress: Double = 0
    @State private var status = "parsing locally on your Mac"
    @State private var feed: [FeedTxn] = []
    @State private var ticker: Task<Void, Never>? = nil

    /// Files being "read": the real imports, or the demo files for the selected
    /// accounts when the user skipped uploading.
    private var files: [(icon: String, name: String, meta: String)] {
        if app.docs.isEmpty {
            return app.selectedAccountKinds.map(AccountKind.byID).map {
                ($0.icon, $0.demoFile, $0.demoMeta)
            }
        }
        return app.docs.map { doc in
            let kind = AccountKind.byID(
                app.uploadsByKind.first { $0.value.contains(doc.name) }?.key ?? "current")
            return (kind.icon, doc.name, "\(doc.rows.count) rows · \(statementTypeLabel(doc.name))")
        }
    }

    private var allRows: [TxnRow] { app.docs.flatMap(\.rows) }
    private var target: Int { allRows.isEmpty ? 2847 : allRows.count }
    private var parsedCount: Int { min(Int(Double(target) * progress), target) }

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
            feedPane
                .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .onAppear(perform: start)
        .onDisappear { ticker?.cancel() }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                PennyAvatar(size: 72, mood: .thinking)
                VStack(alignment: .leading, spacing: 3) {
                    (Text("Reading your ").foregroundColor(Theme.ink)
                     + Text("files").foregroundColor(Theme.limeD)
                     + Text("...").foregroundColor(Theme.ink))
                        .font(Theme.serif(24, .heavy))
                        .kerning(-0.5)
                    Text(status).font(Theme.caveat(15)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(.bottom, 20)

            VStack(spacing: 7) {
                ForEach(Array(files.enumerated()), id: \.offset) { i, file in
                    fileRow(file, index: i)
                }
            }
            .padding(.bottom, 20)

            Text("TRANSACTIONS PARSED")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .kerning(1.2)
                .padding(.bottom, 4)
            Text(parsedCount.formatted())
                .font(Theme.serif(64))
                .kerning(-2.5)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .padding(.bottom, 20)

            HStack(alignment: .top, spacing: 10) {
                Text("🔒")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.ink, lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where your files live").font(Theme.serif(12.5, .heavy)).foregroundStyle(Theme.ink)
                    Text(MD.inline("Stored on this Mac only, inside the app's sandbox. **Never uploaded.**"))
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(3)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.limeS, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.limeD, lineWidth: 2))
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func fileRow(_ file: (icon: String, name: String, meta: String), index: Int) -> some View {
        let n = max(files.count, 1)
        let start = Double(index) / Double(n)
        let end = Double(index + 1) / Double(n)
        let state: (label: String, fill: Color, chipFill: Color, chipText: Color, chipBorder: Color) =
            progress >= end ? ("done ✓", Color(hex: 0xdcfce7), Theme.limeS, Theme.limeD, Theme.limeD)
            : progress >= start ? ("processing", Color(hex: 0xfef3c7), Color(hex: 0xfef3c7), Color(hex: 0x7a3a00), Color(hex: 0xd97706))
            : ("queued", .white, Color(hex: 0xf5f5f5), Theme.dim, Theme.line)
        return HStack(spacing: 10) {
            Text(file.icon)
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(Theme.font(12.5, .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(file.meta).font(Theme.mono(9.5, .semibold)).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 6)
            Text(state.label.uppercased())
                .font(Theme.mono(8.5, .heavy))
                .foregroundStyle(state.chipText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(state.chipFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(state.chipBorder, lineWidth: 1.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(fill: state.fill, radius: 11, border: 2, shadow: 3)
    }

    private var feedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LIVE FEED · DETECTED ACTIVITY")
                Spacer()
                Text("\(parsedCount.formatted()) parsed").foregroundStyle(Theme.limeD)
            }
            .font(Theme.mono(10))
            .foregroundStyle(Theme.dim)
            .kerning(1.2)
            .padding(.bottom, 8)
            DashedRule()
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(feed) { txn in
                        feedRow(txn)
                    }
                }
            }
        }
        .padding(24)
        .background(Theme.bg2)
    }

    private func feedRow(_ txn: FeedTxn) -> some View {
        HStack(spacing: 8) {
            Text(txn.icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(txn.name).font(Theme.font(11, .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(txn.meta).font(Theme.mono(8.5, .semibold)).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 4)
            Text(txn.chip)
                .font(Theme.mono(7.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(txn.chipColor, in: RoundedRectangle(cornerRadius: 4))
            Text(txn.amount)
                .font(Theme.mono(11))
                .foregroundStyle(txn.credit ? Theme.limeD : Theme.ink)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1.5))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // the ~5.4 s parse theatre (the real parse already ran at import time)

    private func start() {
        guard ticker == nil else { return }
        let source = feedSource()
        ticker = Task { @MainActor in
            let duration = 5.4
            let statusMsgs: [(at: Double, text: String)] = [
                (0.0, "opening \(files.first?.name ?? "first file")..."),
                (0.7, "parsing transactions on your Mac..."),
                (1.4, "categorising with \(app.modelDisplayName) 🧠"),
                (2.1, "reading next file..."),
                (2.8, "detecting subscriptions 🔍"),
                (3.5, "merging accounts 🔗"),
                (4.2, "analysing investments 📈"),
                (4.8, "almost ready..."),
            ]
            let started = Date()
            var feedIdx = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                let pct = min(elapsed / duration, 1)
                withAnimation(.linear(duration: 0.05)) { progress = pct }
                if let msg = statusMsgs.last(where: { $0.at <= elapsed }) { status = msg.text }
                let targetFeed = Int(pct * 40)
                while feedIdx < targetFeed && feedIdx < source.count {
                    withAnimation(.easeOut(duration: 0.25)) {
                        feed.insert(source[feedIdx], at: 0)
                        if feed.count > 15 { feed.removeLast() }
                    }
                    feedIdx += 1
                }
                if pct >= 1 {
                    status = "✨ ready · in a moment..."
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled, app.onboardStep == 6 { app.goToStep(7) }
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Real parsed rows when we have them, else the template's sample feed.
    private func feedSource() -> [FeedTxn] {
        let rows = allRows
        if rows.isEmpty { return Self.sampleFeed }
        let cur = app.summary.currency
        return rows.prefix(40).map { r in
            let style = CategoryMeta.style(for: r.category)
            let credit = r.credit > 0 && r.debit == 0
            let amount = credit ? "+\(Money.format(r.credit, currency: cur))"
                                : "-\(Money.format(r.debit, currency: cur))"
            let chip = String(r.category.prefix(5)).uppercased()
            return FeedTxn(icon: style.icon, name: r.descr, meta: r.txnDate,
                           chip: chip, chipColor: style.fill,
                           amount: amount, credit: credit)
        }
    }

    /// The template's `sampleTxns`, looped to 40 entries for the demo path.
    private static let sampleFeed: [FeedTxn] = {
        let base: [(String, String, String, String, Color, String, Bool)] = [
            ("🍱", "Deliveroo", "oct 14 · 10:47pm", "FOOD", Theme.coral, "-£18.40", false),
            ("☕", "Pret a Manger", "oct 14 · 8:14am", "FOOD", Theme.coral, "-£6.80", false),
            ("💷", "Salary · Acme", "oct 14 · 7am", "INC", Theme.mint, "+£3,820", true),
            ("📈", "VWRL purchase", "oct 13 · trade", "INV", Theme.sun, "-£500", false),
            ("🚇", "TfL contactless", "oct 13 · 6:32pm", "TR", Theme.plum, "-£8.30", false),
            ("🛍", "ASOS", "oct 12 · 3:42pm", "SHOP", Theme.peach, "-£87.50", false),
            ("🎵", "Spotify", "oct 12", "SUB", Theme.lime, "-£9.99", false),
            ("💰", "Dividend · VWRL", "oct 12 · payout", "DIV", Theme.sun, "+£23.40", true),
            ("🛒", "Tesco Express", "oct 11 · 7:15pm", "FOOD", Theme.coral, "-£23.40", false),
            ("🚕", "Uber", "oct 11 · 11:23pm", "TR", Theme.plum, "-£18.50", false),
            ("🎧", "Audible", "oct 10", "SUB", Theme.lime, "-£7.99", false),
            ("🎬", "Netflix", "oct 10", "SUB", Theme.lime, "-£10.99", false),
            ("⚡", "Octopus Energy", "oct 9 · DD", "BILLS", Theme.sky, "-£94", false),
            ("📈", "GOOGL · sold 2", "oct 9 · trade", "INV", Theme.sun, "+£287.50", true),
            ("🏛", "Council Tax", "oct 7 · DD", "BILLS", Theme.sky, "-£142", false),
        ]
        return (0..<40).map { i in
            let t = base[i % base.count]
            return FeedTxn(icon: t.0, name: t.1, meta: t.2, chip: t.3,
                           chipColor: t.4, amount: t.5, credit: t.6)
        }
    }()
}

// MARK: - S7 MEETS DATA (.s7)

struct InsightsStep: View {
    @EnvironmentObject var app: AppModel
    @State private var shown = false

    private var rows: [TxnRow] { app.docs.flatMap(\.rows) }
    private var hasData: Bool { !rows.isEmpty }
    private var money: (Double) -> String {
        let cur = app.summary.currency
        return { Money.format($0, currency: cur) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xfef3c7), Color(hex: 0xfed7aa)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 44) {
                mascot
                    .frame(maxWidth: .infinity)
                copy
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 860)
            .padding(32)
        }
        .clipped()
        .onAppear { withAnimation { shown = true } }
    }

    // left — pea with thought bubbles

    private var mascot: some View {
        ZStack {
            PennyAvatar(size: 130, mood: .thinking)
            thought(thoughts.0, delay: 0.3)
                .offset(x: -70, y: -80)
            thought(thoughts.1, delay: 0.7)
                .offset(x: 85, y: 0)
            thought(thoughts.2, delay: 1.1)
                .offset(x: -75, y: 78)
        }
        .frame(height: 260)
    }

    private func thought(_ text: Text, delay: Double) -> some View {
        text
            .font(Theme.caveat(15))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .hardCard(radius: 17, border: 2.5, shadow: 4)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -14)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: shown)
    }

    private var thoughts: (Text, Text, Text) {
        if hasData {
            let ghosts = app.ghostCount
            let biggest = rows.filter { $0.debit > 0 }.max { $0.debit < $1.debit }
            let t1: Text = biggest.map {
                Text("hmm, ") + Text(money($0.debit)).foregroundColor(Theme.limeD).fontWeight(.heavy)
                    + Text(" at \(String($0.descr.prefix(14)))? 👀")
            } ?? Text("interesting reading 👀")
            let t2 = ghosts > 0 ? Text("\(ghosts) recurring subs spotted 🧟")
                                : Text("no zombie subs... yet 🧐")
            let t3 = Text("your ") + Text("\(rows.count)").foregroundColor(Theme.limeD).fontWeight(.heavy)
                + Text(" transactions, all local ✨")
            return (t1, t2, t3)
        }
        return (
            Text("hmm, ") + Text("£187").foregroundColor(Theme.limeD).fontWeight(.heavy) + Text(" on Deliveroo? 👀"),
            Text("3 zombie subs spotted 🧟"),
            Text("your ") + Text("portfolio").foregroundColor(Theme.limeD).fontWeight(.heavy) + Text(" is up 8% ✨")
        )
    }

    // right — headline + insights + CTA

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Let me have a quick\n").foregroundColor(Theme.ink)
             + Text("look at this...").foregroundColor(Theme.limeD))
                .font(Theme.serif(36))
                .kerning(-1)
                .lineSpacing(1)
            Text(intro)
                .font(Theme.font(14.5, .medium))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(4)
                .padding(.top, 9)
                .padding(.bottom, 20)

            VStack(spacing: 7) {
                ForEach(Array(insights.enumerated()), id: \.offset) { i, item in
                    insightRow(item)
                        .opacity(shown ? 1 : 0)
                        .offset(x: shown ? 0 : -18)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3 + Double(i) * 0.3),
                                   value: shown)
                }
            }
            .padding(.bottom, 20)

            HStack {
                Spacer()
                Button { app.finishOnboarding() } label: {
                    Text("Take me to Penny →")
                        .font(Theme.font(15.5, .bold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(LimeButtonStyle(large: true))
            }
        }
    }

    private var intro: String {
        if hasData {
            let s = app.docs.count == 1 ? "statement" : "statements"
            return "\(rows.count.formatted()) transactions read across \(app.docs.count) \(s). Already found a few things — fixable."
        }
        return "2,847 transactions and 1 investment statement read. Already found a few things — fixable."
    }

    private func insightRow(_ item: (icon: String, title: Text, sub: String)) -> some View {
        HStack(spacing: 11) {
            Text(item.icon).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                item.title
                    .font(Theme.serif(14, .bold))
                    .foregroundStyle(Theme.ink)
                Text(item.sub)
                    .font(Theme.mono(9.5, .semibold))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 13, border: 2.5, shadow: 4)
    }

    private var insights: [(icon: String, title: Text, sub: String)] {
        if hasData {
            var out: [(icon: String, title: Text, sub: String)] = []
            if let top = app.summary.categories.first {
                let style = CategoryMeta.style(for: top.name)
                out.append((style.icon,
                            Text("\(top.name) is your top spend — ")
                                + Text(money(top.amount)).foregroundColor(Theme.coral),
                            "summed on-device from your statements"))
            }
            let ghosts = FinanceRouter.recurringCharges(rows)
            if !ghosts.isEmpty {
                let monthly = ghosts.reduce(0) { $0 + $1.amount }
                out.append(("👻",
                            Text("Found ") + Text("\(ghosts.count) recurring charges").foregroundColor(Theme.coral)
                                + Text(" ≈ \(money(monthly))/mo"),
                            ghosts.prefix(3).map(\.name).joined(separator: " · ")))
            }
            if let biggest = rows.filter({ $0.debit > 0 }).max(by: { $0.debit < $1.debit }) {
                out.append(("💸",
                            Text("Biggest single hit: ")
                                + Text(money(biggest.debit)).foregroundColor(Theme.coral),
                            "\(String(biggest.descr.prefix(34))) · \(biggest.txnDate)"))
            }
            if !out.isEmpty { return out }
        }
        return [
            ("🍔", Text("Takeaways up ") + Text("34%").foregroundColor(Theme.coral) + Text(" this month"),
             "£187 on Deliveroo · mostly late-night"),
            ("👻", Text("Found ") + Text("3 zombie subs").foregroundColor(Theme.coral) + Text(" wasting £34/mo"),
             "Audible · FitnessPal · Times+ · all unused"),
            ("📈", Text("Portfolio ") + Text("+8.2%").foregroundColor(Theme.limeD) + Text(" YTD"),
             "VWRL up, GOOGL down, net £1,420 gain"),
        ]
    }
}
