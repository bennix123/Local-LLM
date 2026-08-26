import SwiftUI
import UniformTypeIdentifiers

/// The main app screen — SwiftUI port of `pages/Dashboard.jsx`. Three columns:
/// Sidebar · Chat · Today panel. The PDF importer is owned here and driven from
/// the sidebar's "upload statement" action.
struct DashboardView: View {
    @EnvironmentObject var app: AppModel
    @State private var showingImporter = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                onUpload: { showingImporter = true },
                onSwitchModel: { app.stage = .modelPicker }
            )
            Group {
                switch app.centerView {
                case .chat:    ChatView()
                case .history: ChatHistoryView()
                case .search:  SearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ContextPanelView()
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.pdf, .commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .spreadsheet],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.importStatements(from: urls) }
        }
        // Fix 2 — "help me map this" fallback for a CSV Penny couldn't auto-parse.
        .sheet(item: $app.pendingMapping) { pending in
            ColumnMappingSheet(pending: pending)
                .environmentObject(app)
        }
        .overlay {
            if app.isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Reading statement…")
                            .font(Theme.font(14, .bold)).foregroundStyle(Theme.ink)
                        Text(app.importingName ?? "")
                            .font(Theme.font(11)).foregroundStyle(Theme.dim)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 240)
                    }
                    .padding(28)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: app.isImporting)
        .overlay(alignment: .bottom) {
            if let err = app.errorMessage {
                Text(err)
                    .font(Theme.font(12, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.coral, in: Capsule())
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { app.errorMessage = nil }
            }
        }
    }
}
