import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false
    @State private var errorMessage = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Logo
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 56, height: 56)
                        Text("🎙").font(.system(size: 28))
                    }
                    Text("Transkribering")
                        .font(.system(size: 22, weight: .bold))
                    Text(isRegistering ? "Skapa konto" : "Logga in")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                // Form
                VStack(spacing: 12) {
                    if isRegistering {
                        CustomField(placeholder: "Ditt namn", text: $name, icon: "person")
                    }
                    CustomField(placeholder: "E-postadress", text: $email, icon: "envelope")
                    CustomField(placeholder: "Lösenord", text: $password, icon: "lock", isSecure: true)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                // Primary button
                Button(action: submit) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text(isRegistering ? "Skapa konto" : "Logga in")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
                .buttonStyle(.plain)
                .disabled(isLoading)

                // Toggle
                Button(action: { isRegistering.toggle(); errorMessage = "" }) {
                    Text(isRegistering ? "Har redan ett konto? Logga in" : "Inget konto? Skapa ett")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(32)
            .frame(width: 360)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private func submit() {
        errorMessage = ""
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                if isRegistering {
                    try auth.register(name: name, email: email, password: password)
                } else {
                    try auth.signIn(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct CustomField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    var isSecure = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}
