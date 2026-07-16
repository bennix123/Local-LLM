import SwiftUI
import PennyCore

/// The mandatory "Choose your AI model" step — SwiftUI port of `ModelPicker.jsx`.
/// Unlike the web version (which pulls from Ollama), the native picker lists the
/// MLX catalogue baked into `PennyLLM`; selecting one downloads + loads it via MLX
/// on first use, then continues into the dashboard.
struct ModelPickerView: View {
    @EnvironmentObject var app: AppModel

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(app.catalog, id: \.id) { entry in
                            card(for: entry)
                        }
                    }
                    if let err = app.errorMessage {
                        Text(err).font(Theme.font(12)).foregroundStyle(Theme.coral)
                    }
                    footer
                }
                .padding(32)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("Choose your AI model").font(Theme.font(30, .black)).foregroundStyle(Theme.ink)
                Text(".").font(Theme.font(30, .black)).foregroundStyle(Theme.limeD)
            }
            Text("A required first step — pick the model that powers Penny. Everything runs **fully offline** on this Mac via MLX. The first time you use one, its weights download once; after that it works with no internet.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func card(for entry: PennyLLM.CatalogEntry) -> some View {
        let isSelected = app.selectedModelID == entry.id
        let isLoading: Bool = {
            if case .loading = app.modelPhase, isSelected { return true }
            return false
        }()
        let isReady = isSelected && app.modelPhase == .ready

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.name).font(Theme.font(17, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                if isReady { Text("in use ✓").font(Theme.font(11, .bold)).foregroundStyle(Theme.limeD) }
            }
            Text(entry.id).font(Theme.font(10, .medium).monospaced()).foregroundStyle(Theme.dim).lineLimit(1)
            HStack(spacing: 8) {
                tag(entry.size, bg: Theme.tint)
                tag("≥\(entry.minRAMGB) GB RAM", bg: Theme.tint)
            }
            Text(entry.note).font(Theme.font(12)).foregroundStyle(Theme.dim)

            Spacer(minLength: 4)

            if isLoading {
                progressBlock
            } else {
                Button {
                    app.chooseModel(entry.id)
                    app.errorMessage = nil
                    app.loadAndContinue()
                } label: {
                    Text(isReady ? "In use ✓ · Continue →" : "Use this model")
                        .font(Theme.font(13, .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(isReady ? Theme.limeS : Theme.lime, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(isLoadingAny)
                .opacity(isLoadingAny && !isSelected ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(minHeight: 180, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Theme.limeD : Theme.line, lineWidth: isSelected ? 2.5 : 1)
        )
    }

    private var isLoadingAny: Bool {
        if case .loading = app.modelPhase { return true }
        return false
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.lime)
                        .frame(width: max(4, geo.size.width * CGFloat(app.downloadFraction)))
                        .animation(.easeOut(duration: 0.3), value: app.downloadFraction)
                }
            }
            .frame(height: 8)

            HStack(spacing: 6) {
                Text(app.downloadPercentText)
                    .font(Theme.font(13, .heavy)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if let bytes = app.downloadBytesText {
                    Text("· \(bytes)").font(Theme.font(11, .medium)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Text(app.elapsedText)
                    .font(Theme.font(10, .semibold).monospaced()).foregroundStyle(Theme.dim)
            }
            Text(app.loadStatus).font(Theme.font(10)).foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 6)
    }

    private func tag(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(Theme.font(11, .semibold)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    private var footer: some View {
        HStack {
            Button {
                app.stage = .onboarding
            } label: {
                Text("← back to start").font(Theme.font(12, .semibold)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("You must choose a model before opening the app.")
                .font(Theme.font(11)).foregroundStyle(Theme.dim)
        }
        .padding(.top, 4)
    }
}
