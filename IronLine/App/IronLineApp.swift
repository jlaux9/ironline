import SwiftUI

@main
struct IronLineApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isLocalPrototypeMode {
                HomeView()
            } else if authManager.isLoading {
                ZStack {
                    Theme.Color.background.ignoresSafeArea()
                    ProgressView()
                        .tint(Theme.Color.accent)
                }
            } else if authManager.session == nil {
                LoginView(onTryLocal: appState.enterLocalPrototype)
            } else if appState.currentUser == nil {
                ProfileSetupView()
                    .task { await loadProfile() }
            } else {
                HomeView()
            }
        }
    }

    private func loadProfile() async {
        guard let userId = authManager.session?.user.id else { return }
        appState.currentUser = try? await SupabaseConfig.client
            .from("users")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
    }
}
