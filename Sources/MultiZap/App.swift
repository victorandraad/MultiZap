import SwiftUI
import UserNotifications

@main
struct MultiZapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AccountStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Remove "Nova janela" (não faz sentido aqui).
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Contas") {
                Button("Adicionar conta") { store.add() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Próxima conta") { store.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Conta anterior") { store.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button("Recarregar conta") { WebPool.shared.reload(store.selectedID) }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                // ⌘1…⌘9 trocam de conta direto.
                ForEach(1...9, id: \.self) { n in
                    Button("Ir para conta \(n)") { store.select(index: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // Mostra o banner mesmo com o app em primeiro plano.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicar na notificação abre a conta correspondente.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let idString = response.notification.request.content.userInfo["accountID"] as? String,
           let id = UUID(uuidString: idString) {
            Task { @MainActor in
                AccountStore.shared.selectedID = id
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
