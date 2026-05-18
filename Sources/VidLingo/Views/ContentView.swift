import SwiftUI

struct ContentView: View {
    @Bindable var session: TranslationSessionStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(session: session)
                .frame(width: 300)

            Divider()

            CaptionBoardView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
