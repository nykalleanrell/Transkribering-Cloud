import Foundation
import Security
import Combine

struct User: Codable {
    let email: String
    let name: String
}

class AuthManager: ObservableObject {
    @Published var isLoggedIn = false
    @Published var currentUser: User?

    private let usersKey = "transkribering_users"
    private let sessionKey = "transkribering_session"

    init() {
        // Check for existing session
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            self.currentUser = user
            self.isLoggedIn = true
        }
    }

    // MARK: - Register

    func register(name: String, email: String, password: String) throws {
        var users = loadUsers()
        guard !users.keys.contains(email.lowercased()) else {
            throw AuthError.emailTaken
        }
        let hash = hashPassword(password)
        users[email.lowercased()] = ["name": name, "hash": hash]
        saveUsers(users)
        let user = User(email: email.lowercased(), name: name)
        login(user: user)
    }

    // MARK: - Login

    func signIn(email: String, password: String) throws {
        let users = loadUsers()
        guard let info = users[email.lowercased()] else {
            throw AuthError.notFound
        }
        guard info["hash"] == hashPassword(password) else {
            throw AuthError.wrongPassword
        }
        let name = info["name"] ?? email
        let user = User(email: email.lowercased(), name: name)
        login(user: user)
    }

    // MARK: - Logout

    func signOut() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
        currentUser = nil
        isLoggedIn = false
    }

    // MARK: - Private

    private func login(user: User) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
        currentUser = user
        isLoggedIn = true
    }

    private func hashPassword(_ password: String) -> String {
        // Simple hash — for production, use bcrypt or similar
        var result = 5381
        for char in password.unicodeScalars {
            result = ((result << 5) &+ result) &+ Int(char.value)
        }
        return String(result)
    }

    private func loadUsers() -> [String: [String: String]] {
        guard let data = UserDefaults.standard.data(forKey: usersKey),
              let users = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return users
    }

    private func saveUsers(_ users: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: usersKey)
        }
    }
}

enum AuthError: LocalizedError {
    case emailTaken, notFound, wrongPassword

    var errorDescription: String? {
        switch self {
        case .emailTaken:    return "Den e-postadressen är redan registrerad."
        case .notFound:      return "Inget konto hittades med den e-postadressen."
        case .wrongPassword: return "Fel lösenord."
        }
    }
}
