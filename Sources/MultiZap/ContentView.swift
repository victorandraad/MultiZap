import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var pool = WebPool.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider()
            mainArea
        }
        .ignoresSafeArea()
    }

    /// Todas as contas ficam montadas ao mesmo tempo (recebendo mensagens em
    /// segundo plano). Só a selecionada aparece — as outras ficam invisíveis.
    private var mainArea: some View {
        ZStack {
            if store.accounts.isEmpty {
                emptyState
            } else {
                // Renderiza só as contas montadas (a selecionada + as 'sempre
                // ativas' + as que estão sendo checadas por polling).
                ForEach(store.accounts) { account in
                    if pool.mountedIDs.contains(account.id),
                       let webView = pool.mountedWebView(account.id) {
                        WebContainer(webView: webView)
                            .opacity(account.id == store.selectedID ? 1 : 0)
                            .allowsHitTesting(account.id == store.selectedID)
                    }
                }
                if let sel = store.selectedID, !pool.mountedIDs.contains(sel) {
                    ProgressView("Carregando…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color(hex: "25D366"))
            Text("Nenhuma conta ainda")
                .font(.title2.weight(.semibold))
            Text("Adicione um WhatsApp para começar.")
                .foregroundStyle(.secondary)
            Button {
                store.add()
            } label: {
                Label("Adicionar WhatsApp", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "25D366"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Barra lateral

struct Sidebar: View {
    @ObservedObject private var store = AccountStore.shared

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        AccountButton(account: account, index: index)
                    }
                }
                // Espaço para os botões da janela (semáforos) não colidirem.
                .padding(.top, 40)
            }

            Spacer(minLength: 0)

            Button {
                store.add()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Adicionar conta (⇧⌘N)")
            .padding(.bottom, 14)
        }
        .frame(width: 74)
        .background(.regularMaterial)
    }
}

// MARK: - Ícone de uma conta na barra lateral

struct AccountButton: View {
    let account: Account
    let index: Int

    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var pool = WebPool.shared
    @State private var isRenaming = false
    @State private var draftName = ""

    private var isSelected: Bool { store.selectedID == account.id }
    private var unread: Int { pool.unread[account.id] ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            // Barra de seleção à esquerda.
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Color(hex: account.colorHex) : .clear)
                .frame(width: 4, height: 34)

            Button {
                store.selectedID = account.id
            } label: {
                icon
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .help(account.name)
        .contextMenu { contextMenu }
        .sheet(isPresented: $isRenaming) { renameSheet }
    }

    private var icon: some View {
        // Depende de photoRefresh para recarregar a imagem quando ela muda.
        let _ = store.photoRefresh
        return ZStack(alignment: .topTrailing) {
            Group {
                if account.usePhoto, account.hasPhoto, let image = loadPhoto() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .opacity(isSelected ? 1 : 0.7)
                } else {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(hex: account.colorHex).opacity(isSelected ? 1 : 0.55))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Text(account.initials)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
            )
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 4, y: 1)

            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
                    .overlay(Capsule().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 46, height: 46)
        .contentShape(Rectangle())
    }

    private func loadPhoto() -> NSImage? {
        NSImage(contentsOfFile: AppPaths.photo(account.id).path)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Renomear…") { startRename() }

        if account.hasPhoto {
            if account.usePhoto {
                Button("Usar cor em vez da foto") { store.setUsePhoto(account.id, false) }
            } else {
                Button("Usar foto do perfil") { store.setUsePhoto(account.id, true) }
            }
        }

        Menu("Cor") {
            ForEach(Palette.colors, id: \.self) { hex in
                Button {
                    store.setColor(account, hex: hex)
                } label: {
                    Label {
                        Text(hex == account.colorHex ? "● Atual" : hex)
                    } icon: {
                        Image(systemName: "circle.fill")
                    }
                }
            }
        }

        Menu("Modo") {
            ForEach(AccountMode.allCases) { m in
                Button {
                    store.setMode(account.id, m)
                } label: {
                    if account.mode == m {
                        Label(m.label, systemImage: "checkmark")
                    } else {
                        Text(m.label)
                    }
                }
            }
        }

        Button("Recarregar") { pool.reload(account.id) }

        Divider()

        Button("Sair desta conta…", role: .destructive) {
            pool.clearSession(account.id)
        }
        Button("Remover conta", role: .destructive) {
            store.remove(account)
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Renomear conta")
                .font(.headline)
            TextField("Nome", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancelar") { isRenaming = false }
                Button("Salvar") { commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func startRename() {
        draftName = account.name
        isRenaming = true
    }

    private func commitRename() {
        store.rename(account, to: draftName)
        isRenaming = false
    }
}
