import SwiftUI

struct LoginView: View {
    @ObservedObject var model: ChargerViewModel
    @State private var email: String = KeychainStore.email ?? ""
    @State private var password: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Ohme")
                .font(.headline)

            Text("Use your Ohme account email and password. Accounts created with Google or Apple sign-in need a password reset first.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption2)
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty || model.isLoading)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        Task { await model.logIn(email: email, password: password) }
    }
}
