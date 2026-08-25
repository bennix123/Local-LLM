// OnboardingFlow — the mockup's three screens, made real:
//   1. Hook       — "Talk to your money." (verbatim from penny_final_1)
//   2. Add        — statement import (PDF/CSV/XLSX, up to 10). The mockup showed
//                   an Open Banking connect; Penny's privacy story is the
//                   opposite — files you choose, parsed on-device — so this
//                   screen keeps the mockup's layout with honest content.
//   3. Sync       — the big serif counter, counting rows actually parsed.
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingFlow: View {
    @EnvironmentObject var model: IOSModel
    @State private var step = 1
    @State private var showImporter = false

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            switch step {
            case 1: hook
            case 2: addStatements
            default: sync
            }
        }
        .animation(.easeInOut(duration: 0.35), value: step)
    }

    // MARK: 1 · hook

    private var hook: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(T.limeDeep).frame(width: 6, height: 6)
                Text("ON-DEVICE · ALWAYS").font(T.mono(10, .semibold)).kerning(1.8)
            }
            .foregroundStyle(T.limeDeep)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(T.limeSoft, in: Capsule())
            .padding(.bottom, 24)

            (Text("Talk to your ").foregroundStyle(T.ink)
             + Text("money.").foregroundStyle(T.limeDeep))
                .font(T.display(46))
                .lineSpacing(2)
                .padding(.bottom, 16)

            Text("Penny lives entirely on your phone. It reads your statements, does the maths deterministically, and the AI never touches a number. Nothing leaves the device.")
                .font(T.body(15)).foregroundStyle(T.dim)
                .lineSpacing(4)
                .padding(.bottom, 32)

            Button { step = 2 } label: {
                Text("Get started")
                    .font(T.body(16, .bold)).foregroundStyle(T.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(T.lime, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(.horizontal, 32).padding(.bottom, 44)
        .background(alignment: .topTrailing) {
            Circle().fill(T.peach).frame(width: 340).blur(radius: 110).opacity(0.45)
                .offset(x: 110, y: -130)
        }
        .background(alignment: .bottomLeading) {
            Circle().fill(T.lime).frame(width: 340).blur(radius: 110).opacity(0.35)
                .offset(x: -130, y: 110)
        }
    }

    // MARK: 2 · add statements

    private var addStatements: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { step = 1 } label: {
                Text("← back").font(T.mono(11)).foregroundStyle(T.dim)
            }
            .padding(.bottom, 24)

            (Text("Add a ").foregroundStyle(T.ink) + Text("statement").foregroundStyle(T.limeDeep))
                .font(T.display(32, .bold))
                .padding(.bottom, 8)
            Text("Export statements from your banking app — PDF, CSV or Excel — and drop up to 10 here. Parsed on this phone by the same engine as Penny for Mac.")
                .font(T.body(14)).foregroundStyle(T.dim).lineSpacing(3)
                .padding(.bottom, 24)

            Button { showImporter = true } label: {
                VStack(spacing: 8) {
                    Text("📄").font(.system(size: 34))
                    Text("Choose statement files").font(T.body(15, .bold)).foregroundStyle(T.ink)
                    Text("PDF · CSV · XLSX — up to 10 at once")
                        .font(T.body(12)).foregroundStyle(T.dim)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34)
                .background(T.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(T.line, style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                )
            }

            if !model.importErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.importErrors, id: \.self) { e in
                        Text(e).font(T.body(12)).foregroundStyle(T.coral)
                    }
                }
                .padding(.top, 14)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle().fill(T.limeDeep).frame(width: 5, height: 5)
                Text("data lives on your phone · nothing is uploaded")
                    .font(T.mono(10)).kerning(1)
            }
            .foregroundStyle(T.limeDeep)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(T.limeSoft, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 28)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf, .commaSeparatedText,
                                            UTType(filenameExtension: "xlsx") ?? .spreadsheet],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                step = 3
                model.importStatements(from: urls)
            }
        }
    }

    // MARK: 3 · sync (real numbers)

    private var sync: some View {
        VStack(spacing: 0) {
            Spacer()
            if model.isImporting {
                ProgressView().controlSize(.large).tint(T.limeDeep).padding(.bottom, 26)
            }
            Text("\(model.importedRowCount)")
                .font(T.display(56, .semibold)).foregroundStyle(T.ink)
                .contentTransition(.numericText())
                .animation(.snappy, value: model.importedRowCount)
                .padding(.bottom, 8)
            Text(model.importStatus)
                .font(T.mono(11)).kerning(0.5).foregroundStyle(T.dim)

            if !model.isImporting {
                if model.hasData {
                    Button { model.onboarded = true } label: {
                        Text("Open Penny →")
                            .font(T.body(16, .bold)).foregroundStyle(T.ink)
                            .padding(.horizontal, 40).padding(.vertical, 15)
                            .background(T.lime, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, 34)
                } else {
                    Button { step = 2 } label: {
                        Text("← try different files").font(T.mono(12)).foregroundStyle(T.dim)
                    }
                    .padding(.top, 30)
                }
                if !model.importErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.importErrors, id: \.self) { e in
                            Text(e).font(T.body(12)).foregroundStyle(T.coral)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.horizontal, 32).padding(.top, 18)
                }
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(T.limeDeep).frame(width: 5, height: 5)
                Text("processing locally · 0 bytes uploaded").font(T.mono(10)).kerning(1.2)
            }
            .foregroundStyle(T.limeDeep)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(T.limeSoft, in: Capsule())
            .padding(.bottom, 40)
        }
    }
}
