import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var currentUser: UserProfile?
    @Published var isLocalPrototypeMode = false

    func enterLocalPrototype() {
        currentUser = nil
        isLocalPrototypeMode = true
    }
}
