import SwiftUI

struct MemorySearchResultsView<History: View, Latest: View>: View {
    let latestID: String
    let hasHistory: Bool
    let maxHeight: CGFloat
    @Binding var contentHeight: CGFloat
    @ViewBuilder var history: () -> History
    @ViewBuilder var latest: () -> Latest
    @State private var position: String?

    private var viewportHeight: CGFloat { min(maxHeight, max(44, contentHeight)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16, content: history).id("search-history")
                // Leave room below a short follow-up so its question can reach the top.
                VStack(alignment: .leading, spacing: 16, content: latest)
                    .frame(maxWidth: .infinity, minHeight: hasHistory ? max(0, viewportHeight - 32) : 0, alignment: .topLeading)
                    .id(latestID)
            }
            .scrollTargetLayout()
            .padding(16)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SearchResultsHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(height: viewportHeight)
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition(id: $position, anchor: .top)
        .onPreferenceChange(SearchResultsHeightKey.self) { height in
            if abs(contentHeight - height) > 1 { contentHeight = height }
        }
        // A declarative target is resolved after layout, including newly inserted answers.
        .onChange(of: latestID, initial: true) { _, id in position = id }
    }
}

private struct SearchResultsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
