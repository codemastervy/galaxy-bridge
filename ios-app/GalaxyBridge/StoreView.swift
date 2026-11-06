import SafariServices
import SwiftUI
import WebKit

/// Google Play's own web pages, inside the app. When a page is an app or watch face, an
/// "Install on watch" bar appears; it opens that page in the Play Store on the watch, where
/// you tap Install. Browsing needs no sign-in; anything that asks for a Google account opens
/// in Safari instead, so this app never sees account pages. Nothing is stored between visits.
struct StoreScreen: View {
    @EnvironmentObject var hub: FeatureHub
    @StateObject private var web = StoreWeb()
    @State private var section = 0
    @State private var query = ""

    private static let faces = URL(string: "https://play.google.com/store/apps/category/WATCH_FACE")!
    private static let watchApps = URL(string: "https://play.google.com/store/search?q=wear%20os&c=apps")!
    private static let sections: [(String, URL)] = [("Watch faces", faces), ("Watch apps", watchApps)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Self.sections.indices, id: \.self) { Text(Self.sections[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)

            StoreWebView(web: web)
                .overlay { if web.loading { ProgressView() } }

            if let pkg = web.packageName {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(web.title ?? "This app").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(pkg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { hub.openStore(pkg) } label: {
                        Label("Install on watch", systemImage: "applewatch.and.arrow.forward")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.default, value: web.packageName)
        .navigationTitle("Google Play")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search watch apps and faces")
        .onSubmit(of: .search) {
            var c = URLComponents(string: "https://play.google.com/store/search")!
            c.queryItems = [.init(name: "q", value: query + " wear os"), .init(name: "c", value: "apps")]
            if let url = c.url { web.load(url) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { web.back() } label: { Image(systemName: "chevron.backward") }.disabled(!web.canGoBack)
            }
        }
        .onAppear { if web.webView.url == nil { web.load(Self.sections[section].1) } }
        .onChange(of: section) { _, s in web.load(Self.sections[s].1) }
        .sheet(item: $web.external) { SafariView(url: $0.url).ignoresSafeArea() }
        .toast($hub.toast)
    }
}

@MainActor
final class StoreWeb: NSObject, ObservableObject, WKNavigationDelegate {
    struct External: Identifiable { let url: URL; var id: URL { url } }

    @Published private(set) var packageName: String?
    @Published private(set) var title: String?
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published var external: External?

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.url) { [weak self] v, _ in
                let url = v.url
                Task { @MainActor in self?.update(url) }
            },
            webView.observe(\.title) { [weak self] v, _ in
                let t = v.title
                Task { @MainActor in self?.title = t.map { $0.replacingOccurrences(of: " - Apps on Google Play", with: "") } }
            },
            webView.observe(\.isLoading) { [weak self] v, _ in
                let l = v.isLoading
                Task { @MainActor in self?.loading = l; self?.canGoBack = v.canGoBack }
            },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func back() { webView.goBack() }

    private func update(_ url: URL?) {
        canGoBack = webView.canGoBack
        guard let url, url.host == "play.google.com", url.path.hasPrefix("/store/apps/details"),
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              id.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil else {
            packageName = nil
            return
        }
        packageName = id
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        do {
            guard let url, let host = url.host else { return decisionHandler(.allow) }
            // Stay on Play's own pages; send sign-in and everything else to Safari.
            let allowed = host == "play.google.com" || host.hasSuffix(".gstatic.com") || host.hasSuffix(".googleusercontent.com")
                || host == "www.gstatic.com" || host == "play-lh.googleusercontent.com"
            if allowed || action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if url.scheme == "https" { external = External(url: url) }
            }
        }
    }
}

struct StoreWebView: UIViewRepresentable {
    let web: StoreWeb
    func makeUIView(context: Context) -> WKWebView { web.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
