// RootTabs — the mockup's app shell: brand bar (penny. wordmark + on-device
// pill) over a 4-tab layout with Chat at the centre of the product.
import SwiftUI

struct RootTabs: View {
    @EnvironmentObject var model: IOSModel
    @State private var tab: Tab = .chat
    @State private var showSearch = false

    enum Tab { case today, chat, patterns, bills }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $tab) {
                TodayView().tag(Tab.today)
                    .tabItem { Label("Today", systemImage: "house.fill") }
                ChatViewIOS().tag(Tab.chat)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                PatternsView().tag(Tab.patterns)
                    .tabItem { Label("Patterns", systemImage: "bolt.fill") }
                BillsView().tag(Tab.bills)
                    .tabItem { Label("Bills", systemImage: "bell.fill") }
            }
        }
        .background(T.bg.ignoresSafeArea())
        .toolbarBackground(T.bg, for: .tabBar)
        .sheet(isPresented: $showSearch) { SearchSheet() }
        .sheet(item: $model.pendingMapping) { pending in
            ColumnMappingSheetIOS(pending: pending).environmentObject(model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            (Text("penny").foregroundStyle(T.ink) + Text(".").foregroundStyle(T.limeDeep))
                .font(T.display(24, .heavy))
            Spacer()
            if model.hasData {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T.ink)
                }
                .accessibilityLabel("Search transactions")
            }
            Menu {
                Button(role: .destructive) { model.wipeAll(); model.onboarded = false } label: {
                    Label("Wipe all data", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(T.limeDeep).frame(width: 5, height: 5)
                    Text("on-device").font(T.mono(9, .semibold))
                }
                .foregroundStyle(T.limeDeep)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(T.limeSoft, in: Capsule())
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)
        .background(T.bg)
    }
}
