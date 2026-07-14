import SwiftUI

// MARK: - Paleta de cores das contas

enum Palette {
    static let colors: [String] = [
        "25D366", "34B7F1", "A66CFF", "FF6B6B",
        "FFB84C", "20C997", "F06595", "5C7CFA",
    ]
    static func color(at index: Int) -> String { colors[index % colors.count] }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Modo de funcionamento da conta

enum AccountMode: String, Codable, CaseIterable, Identifiable {
    case alive    // sempre conectada (notificação na hora, mais RAM)
    case polling  // dorme e acorda periodicamente (RAM baixa, notificação atrasada)
    case manual   // só carrega quando você abre (RAM zero, sem notificação)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alive:   return "Sempre ativa"
        case .polling: return "Economia"
        case .manual:  return "Manual"
        }
    }

    var detail: String {
        switch self {
        case .alive:   return "Conectada o tempo todo. Notificação na hora, usa mais RAM."
        case .polling: return "Dorme e acorda de tempos em tempos pra checar. RAM baixa, notificação atrasada."
        case .manual:  return "Fica desligada até você abrir. RAM zero, sem notificação em segundo plano."
        }
    }
}

// MARK: - Caminhos em disco (fotos de perfil)

enum AppPaths {
    static var photosDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiZap/photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func photo(_ id: UUID) -> URL {
        photosDir.appendingPathComponent("\(id.uuidString).jpg")
    }
}

// MARK: - Modelo de conta

struct Account: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var colorHex: String
    var isNameCustom: Bool
    var hasPhoto: Bool
    var usePhoto: Bool
    var mode: AccountMode

    init(id: UUID, name: String, colorHex: String,
         isNameCustom: Bool = false, hasPhoto: Bool = false,
         usePhoto: Bool = true, mode: AccountMode = .polling) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isNameCustom = isNameCustom
        self.hasPhoto = hasPhoto
        self.usePhoto = usePhoto
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, isNameCustom, hasPhoto, usePhoto, mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        isNameCustom = try c.decodeIfPresent(Bool.self, forKey: .isNameCustom) ?? false
        hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
        usePhoto = try c.decodeIfPresent(Bool.self, forKey: .usePhoto) ?? true
        mode = try c.decodeIfPresent(AccountMode.self, forKey: .mode) ?? .polling
    }

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first }.map(String.init)
        let joined = chars.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }
}

// MARK: - Armazenamento (persistido em UserDefaults)

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accounts: [Account] { didSet { save() } }
    @Published var selectedID: UUID? {
        didSet {
            saveSelection()
            if ready { WebPool.shared.reconcile() }
        }
    }
    @Published var pollMinutes: Int { didSet { UserDefaults.standard.set(pollMinutes, forKey: pollKey) } }
    @Published var photoRefresh = 0

    private let accountsKey = "multizap.accounts.v2"
    private let selectionKey = "multizap.selection"
    private let pollKey = "multizap.pollMinutes"
    private var ready = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data),
           !decoded.isEmpty {
            accounts = decoded
        } else {
            accounts = [
                Account(id: UUID(), name: "Conta 1", colorHex: Palette.color(at: 0), mode: .polling),
                Account(id: UUID(), name: "Conta 2", colorHex: Palette.color(at: 1), mode: .polling),
            ]
        }

        let savedPoll = UserDefaults.standard.integer(forKey: pollKey)
        pollMinutes = savedPoll >= 1 ? savedPoll : 15

        if let str = UserDefaults.standard.string(forKey: selectionKey),
           let uuid = UUID(uuidString: str),
           accounts.contains(where: { $0.id == uuid }) {
            selectedID = uuid
        } else {
            selectedID = accounts.first?.id
        }

        ready = true
        // Primeira reconciliação depois que o init retornar (evita reentrar no
        // singleton, que ainda não terminou de ser criado aqui dentro).
        DispatchQueue.main.async { WebPool.shared.reconcile() }
    }

    // MARK: Ações

    func add() {
        let account = Account(
            id: UUID(),
            name: "Conta \(accounts.count + 1)",
            colorHex: Palette.color(at: accounts.count),
            mode: .polling
        )
        accounts.append(account)
        selectedID = account.id
    }

    func remove(_ account: Account) {
        WebPool.shared.dispose(account.id)
        accounts.removeAll { $0.id == account.id }
        if selectedID == account.id { selectedID = accounts.first?.id }
    }

    func rename(_ account: Account, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = index(of: account) else { return }
        accounts[idx].name = trimmed
        accounts[idx].isNameCustom = true
    }

    func setColor(_ account: Account, hex: String) {
        guard let idx = index(of: account) else { return }
        accounts[idx].colorHex = hex
        accounts[idx].usePhoto = false
    }

    func setUsePhoto(_ id: UUID, _ value: Bool) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].usePhoto = value
    }

    func setMode(_ id: UUID, _ mode: AccountMode) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].mode = mode
        WebPool.shared.reconcile()
    }

    func applyAutoName(_ name: String, to id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }),
              !accounts[idx].isNameCustom,
              accounts[idx].name != name else { return }
        accounts[idx].name = name
    }

    func markPhoto(_ id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        if !accounts[idx].hasPhoto { accounts[idx].hasPhoto = true }
        photoRefresh += 1
    }

    func select(index: Int) {
        guard accounts.indices.contains(index) else { return }
        selectedID = accounts[index].id
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        guard !accounts.isEmpty, let current = selectedID,
              let idx = accounts.firstIndex(where: { $0.id == current }) else { return }
        selectedID = accounts[(idx + delta + accounts.count) % accounts.count].id
    }

    var selectedAccount: Account? { accounts.first { $0.id == selectedID } }
    private func index(of account: Account) -> Int? { accounts.firstIndex(where: { $0.id == account.id }) }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }
    private func saveSelection() {
        UserDefaults.standard.set(selectedID?.uuidString, forKey: selectionKey)
    }
}
