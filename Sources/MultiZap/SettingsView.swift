import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = AccountStore.shared

    private let intervals = [5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                Picker("Checar contas em economia a cada", selection: $store.pollMinutes) {
                    ForEach(intervals, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Verificação em segundo plano")
            } footer: {
                Text("Contas em modo Economia dormem (RAM ~zero) e acordam nesse intervalo só pra checar mensagens novas — a notificação chega com esse atraso.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modo de cada conta") {
                ForEach(store.accounts) { account in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).fontWeight(.medium)
                            Text(account.mode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { account.mode },
                            set: { store.setMode(account.id, $0) }
                        )) {
                            ForEach(AccountMode.allCases) { m in Text(m.label).tag(m) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sempre ativa — conectada o tempo todo. Notifica na hora, usa mais RAM.", systemImage: "bolt.fill")
                    Label("Economia — dorme e checa periodicamente. RAM baixa, notificação atrasada.", systemImage: "leaf.fill")
                    Label("Manual — só liga quando você abre. RAM zero, sem notificação de fundo.", systemImage: "hand.tap.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }
}
