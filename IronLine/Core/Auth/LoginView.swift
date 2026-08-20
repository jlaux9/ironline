import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authManager: AuthManager

    var onTryLocal: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showSignUp = false

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 10) {
                    Text("IRONLINE")
                        .font(.caption.weight(.black))
                        .tracking(5)
                        .foregroundStyle(Theme.Color.accent)

                    Text("BEAT\nEXPECTATION.")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Theme.Color.textPrimary)

                    Text("The camera is the referee. THE LINE is the opponent.")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(14)
                        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await logIn() }
                    } label: {
                        Text("LOG IN")
                            .font(.headline.weight(.black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.Color.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
                    }

                    Button(action: onTryLocal) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                            Text("ENTER FIRST PLAYABLE")
                        }
                        .font(.subheadline.weight(.black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .background(Theme.Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.button)
                                .stroke(Theme.Color.textSecondary.opacity(0.25), lineWidth: 1)
                        }
                    }

                    Button("Create Account") { showSignUp = true }
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
    }

    private func logIn() async {
        errorMessage = nil
        do {
            try await authManager.signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
