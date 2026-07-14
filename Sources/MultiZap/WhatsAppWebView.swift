import SwiftUI
import WebKit
import UserNotifications

/// Gerencia o ciclo de vida dos webviews por conta conforme o modo:
/// - alive:   sempre montado (conectado, notifica na hora).
/// - polling: hiberna (sem webview) e acorda a cada N min pra checar.
/// - manual:  só existe quando a conta está selecionada.
/// A conta selecionada está sempre montada (você está vendo ela).
@MainActor
final class WebPool: ObservableObject {
    static let shared = WebPool()

    @Published private(set) var unread: [UUID: Int] = [:]
    /// Contas cujos webviews estão montados agora (a UI renderiza só estas).
    @Published private(set) var mountedIDs: [UUID] = []

    private var views: [UUID: WKWebView] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var delegates: [UUID: WebNavigator] = [:]
    private var bridges: [UUID: WebBridge] = [:]

    // Estado de polling
    private var pollingNow: Set<UUID> = []
    private var lastPoll: [UUID: Date] = [:]
    private var lastNotifiedUnread: [UUID: Int] = [:]
    private var pollWork: [UUID: DispatchWorkItem] = [:]
    private var pollTimer: Timer?

    /// Quanto tempo o webview fica acordado numa checagem de polling.
    private static let pollWindow: TimeInterval = 25

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private init() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyVisibility() }
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
    }

    // MARK: - Reconciliação (quem deve estar montado)

    func reconcile() {
        let store = AccountStore.shared
        let selected = store.selectedID

        var desired = Set<UUID>()
        for acc in store.accounts {
            if acc.id == selected { desired.insert(acc.id) }
            else if acc.mode == .alive { desired.insert(acc.id) }
        }
        desired.formUnion(pollingNow)

        for id in Array(views.keys) where !desired.contains(id) {
            teardown(id)
        }
        for acc in store.accounts where desired.contains(acc.id) {
            ensureLive(acc)
        }

        mountedIDs = store.accounts.map(\.id).filter { views.keys.contains($0) }
        setVisibility(selected: selected)
    }

    func mountedWebView(_ id: UUID) -> WKWebView? { views[id] }

    // MARK: - Criação / destruição

    private func ensureLive(_ account: Account) {
        guard views[account.id] == nil else { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
        config.mediaTypesRequiringUserActionForPlayback = []

        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Self.visibilityJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.notificationJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.identityJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let bridge = WebBridge(accountID: account.id)
        ucc.add(bridge, name: "notify")
        ucc.add(bridge, name: "identity")
        bridges[account.id] = bridge
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.allowsBackForwardNavigationGestures = false

        let navigator = WebNavigator()
        webView.navigationDelegate = navigator
        webView.uiDelegate = navigator
        delegates[account.id] = navigator

        observations[account.id] = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            let title = (change.newValue ?? nil) ?? ""
            let count = Self.unreadCount(from: title)
            Task { @MainActor in self?.setUnread(count, for: account.id) }
        }

        webView.load(URLRequest(url: URL(string: "https://web.whatsapp.com")!))
        views[account.id] = webView
    }

    /// Destrói o webview (libera RAM) mas mantém a sessão em disco e a foto.
    private func teardown(_ id: UUID) {
        // Guarda o último não lido conhecido para o polling só avisar novidades.
        if lastNotifiedUnread[id] == nil { lastNotifiedUnread[id] = unread[id] ?? 0 }
        observations[id]?.invalidate(); observations[id] = nil
        delegates[id] = nil
        bridges[id] = nil
        if let wv = views[id] {
            wv.configuration.userContentController.removeAllScriptMessageHandlers()
            wv.stopLoading()
            wv.removeFromSuperview()
        }
        views[id] = nil
    }

    /// Remoção definitiva de uma conta (apaga foto e estado).
    func dispose(_ id: UUID) {
        pollWork[id]?.cancel(); pollWork[id] = nil
        pollingNow.remove(id)
        teardown(id)
        unread[id] = nil
        lastPoll[id] = nil
        lastNotifiedUnread[id] = nil
        try? FileManager.default.removeItem(at: AppPaths.photo(id))
        mountedIDs = AccountStore.shared.accounts.map(\.id).filter { views.keys.contains($0) }
        updateDockBadge()
    }

    func reload(_ id: UUID?) {
        guard let id, let webView = views[id] else { return }
        webView.reload()
    }

    func clearSession(_ id: UUID) {
        guard let webView = views[id] else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
            webView.reload()
        }
    }

    // MARK: - Polling

    private func pollTick() {
        let store = AccountStore.shared
        let selected = store.selectedID
        let interval = TimeInterval(max(1, store.pollMinutes) * 60)
        let now = Date()
        for acc in store.accounts
        where acc.mode == .polling && acc.id != selected && !pollingNow.contains(acc.id) {
            let last = lastPoll[acc.id] ?? .distantPast
            if now.timeIntervalSince(last) >= interval {
                startPoll(acc.id)
            }
        }
    }

    private func startPoll(_ id: UUID) {
        pollingNow.insert(id)
        reconcile() // monta o webview (fora da tela) pra ele conectar
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishPoll(id) }
        }
        pollWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollWindow, execute: work)
    }

    private func finishPoll(_ id: UUID) {
        pollWork[id] = nil
        pollingNow.remove(id)
        lastPoll[id] = Date()

        let count = unread[id] ?? 0
        let previouslyNotified = lastNotifiedUnread[id] ?? 0
        if count > previouslyNotified {
            postGenericNotification(accountID: id, count: count)
        }
        lastNotifiedUnread[id] = count

        reconcile() // hiberna de novo (a menos que tenha virado selecionada)
    }

    // MARK: - Visibilidade (contas 'alive' de fundo precisam notificar)

    func setVisibility(selected: UUID?) {
        let appActive = NSApplication.shared.isActive
        for (id, webView) in views {
            let hidden = !appActive || id != selected
            webView.evaluateJavaScript("window.__mzSetHidden && window.__mzSetHidden(\(hidden))",
                                       completionHandler: nil)
        }
    }

    func applyVisibility() { setVisibility(selected: AccountStore.shared.selectedID) }

    // MARK: - Mensagens do JS

    fileprivate func handleBridge(name: String, body: Any, accountID: UUID) {
        guard let dict = body as? [String: Any] else { return }
        switch name {
        case "notify":
            // Durante um poll usamos a notificação genérica (evita spam do sync).
            if pollingNow.contains(accountID) { return }
            let sender = (dict["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "WhatsApp"
            let text = (dict["body"] as? String) ?? ""
            postContentNotification(accountID: accountID, sender: sender, text: text)
        case "identity":
            if let name = dict["name"] as? String { AccountStore.shared.applyAutoName(name, to: accountID) }
            if let photoURL = dict["photoURL"] as? String { downloadPhoto(urlString: photoURL, for: accountID) }
        default:
            break
        }
    }

    private func postContentNotification(accountID: UUID, sender: String, text: String) {
        let accountName = AccountStore.shared.accounts.first { $0.id == accountID }?.name
        let content = UNMutableNotificationContent()
        content.title = sender
        if let accountName, accountName != sender { content.subtitle = accountName }
        content.body = text
        content.sound = .default
        content.userInfo = ["accountID": accountID.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func postGenericNotification(accountID: UUID, count: Int) {
        let name = AccountStore.shared.accounts.first { $0.id == accountID }?.name ?? "WhatsApp"
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = count == 1 ? "1 mensagem nova" : "\(count) mensagens novas"
        content.sound = .default
        content.userInfo = ["accountID": accountID.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func downloadPhoto(urlString: String, for id: UUID) {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, data.count > 500, NSImage(data: data) != nil else { return }
            try? data.write(to: AppPaths.photo(id))
            Task { @MainActor in AccountStore.shared.markPhoto(id) }
        }.resume()
    }

    // MARK: - Não lidas / badge

    private func setUnread(_ count: Int, for id: UUID) {
        unread[id] = count
        updateDockBadge()
    }

    private func updateDockBadge() {
        let total = unread.values.reduce(0, +)
        NSApplication.shared.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    private nonisolated static func unreadCount(from title: String) -> Int {
        guard let range = title.range(of: #"\((\d+)\)"#, options: .regularExpression) else { return 0 }
        let digits = title[range].filter { $0.isNumber }
        return Int(digits) ?? 0
    }
}

// MARK: - Scripts injetados

extension WebPool {
    static let visibilityJS = """
    (function(){
      if (window.__mzVis) return; window.__mzVis = true;
      var hidden = false;
      try {
        Object.defineProperty(document, 'hidden', { get: function(){ return hidden; }, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: function(){ return hidden ? 'hidden' : 'visible'; }, configurable: true });
      } catch(e){}
      document.hasFocus = function(){ return !hidden; };
      window.__mzSetHidden = function(h){
        h = !!h; if (h === hidden) return; hidden = h;
        try { document.dispatchEvent(new Event('visibilitychange')); } catch(e){}
        try { window.dispatchEvent(new Event(h ? 'blur' : 'focus')); } catch(e){}
      };
    })();
    """

    static let notificationJS = """
    (function(){
      if (window.__mzNotif) return; window.__mzNotif = true;
      function send(title, options){
        options = options || {};
        try {
          window.webkit.messageHandlers.notify.postMessage({
            title: String(title || ''), body: String(options.body || ''), tag: String(options.tag || '')
          });
        } catch(e){}
      }
      function MZNotification(title, options){
        send(title, options);
        this.title = title; this.onclick = null;
        this.close = function(){}; this.addEventListener = function(){}; this.removeEventListener = function(){};
      }
      MZNotification.permission = 'granted';
      MZNotification.requestPermission = function(cb){ if (cb) cb('granted'); return Promise.resolve('granted'); };
      try { window.Notification = MZNotification; } catch(e){}
      try {
        if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype) {
          ServiceWorkerRegistration.prototype.showNotification = function(title, options){ send(title, options); return Promise.resolve(); };
        }
      } catch(e){}
    })();
    """

    static let identityJS = """
    (function(){
      if (window.__mzIdent) return; window.__mzIdent = true;
      var sentPhoto = false, sentName = false, ticks = 0;
      function post(o){ try { window.webkit.messageHandlers.identity.postMessage(o); } catch(e){} }
      function getPhone(){
        try {
          for (var i=0;i<localStorage.length;i++){
            var k = localStorage.key(i);
            if (k && k.toLowerCase().indexOf('wid') !== -1){
              var v = localStorage.getItem(k) || '';
              var m = v.replace(/[^0-9@:]/g,'');
              if (m.indexOf('@') !== -1) m = m.split('@')[0];
              m = m.split(':')[0];
              if (m.length >= 8) return '+' + m;
            }
          }
        } catch(e){}
        return null;
      }
      function profileImg(){
        var labels = ['Perfil','Profile','Tú','You','Profil','Mein Profil','Meu perfil','个人资料','プロフィール'];
        for (var i=0;i<labels.length;i++){
          var el = document.querySelector('[aria-label="'+labels[i]+'"] img') || document.querySelector('img[aria-label="'+labels[i]+'"]');
          if (el && el.src) return el;
        }
        var imgs = Array.prototype.slice.call(document.querySelectorAll('img'));
        var cand = imgs.filter(function(im){ var r = im.getBoundingClientRect(); return r.width > 0 && r.left < 45 && r.width < 60; });
        return cand.length ? cand[0] : null;
      }
      function tick(){
        ticks++;
        if (!sentName){ var p = getPhone(); if (p){ post({name: p}); sentName = true; } }
        if (!sentPhoto){ var im = profileImg(); if (im && im.src && im.src.indexOf('http') === 0){ post({photoURL: im.src}); sentPhoto = true; } }
        if (sentName && sentPhoto){ clearInterval(iv); }
      }
      var iv = setInterval(tick, 3000); tick();
    })();
    """
}

// MARK: - Ponte JS -> Swift

final class WebBridge: NSObject, WKScriptMessageHandler {
    let accountID: UUID
    init(accountID: UUID) { self.accountID = accountID }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            WebPool.shared.handleBridge(name: message.name, body: message.body, accountID: accountID)
        }
    }
}

// MARK: - Delegate de navegação

final class WebNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in WebPool.shared.applyVisibility() }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

// MARK: - Ponte SwiftUI: mostra um WKWebView existente

struct WebContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }
}
