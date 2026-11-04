import SwiftUI
import TroveCore
import WebKit

/// A board's own website, for the papers the catalogue can't list: CCEA (its site blocks cloud machines,
/// so nothing can read it for you) and Pearson's newest series (behind your Pearson login). You browse the
/// real site on your own connection; on a PDF, "Add to Trove" saves it as one of your papers, named the
/// way uploads are. Nothing here is automated: it's you, on the board's site, choosing a paper.
struct BoardSite: Identifiable, Hashable {
    let id: String
    let name: String
    let start: URL
    let hint: String
    var menuTitle: String { "\(name)…" }

    static let all = [
        BoardSite(id: "ccea", name: "CCEA", start: URL(string: "https://ccea.org.uk/")!,
                  hint: "Find your subject's page, then its past papers and mark schemes. Open a paper and tap Add to Trove."),
        BoardSite(id: "pearson", name: "Pearson Edexcel (newest papers)",
                  start: URL(string: "https://qualifications.pearson.com/en/support/support-topics/exams/past-papers.html")!,
                  hint: "The newest series need you to sign in to Pearson. Open a paper and tap Add to Trove."),
    ]
}

/// The web view's state and delegates: which page is a PDF, and saving it through the web view's own
/// session (so a site you've signed in to hands over the file as it would to your browser).
@MainActor
@Observable
final class BoardBrowserState: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    var pdfURL: URL?
    var title = ""
    var canGoBack = false
    var loading = false
    var saving = false
    var message: String?
    @ObservationIgnored var onFile: ((Data, String, URL?) -> Void)?
    @ObservationIgnored private var downloads: [ObjectIdentifier: (file: URL, name: String, source: URL?)] = [:]

    init(start: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps a board login between visits, on this device only
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: start))
    }

    static func isPDF(_ response: URLResponse) -> Bool {
        response.mimeType == "application/pdf" || response.url?.pathExtension.lowercased() == "pdf"
    }

    func addCurrentPDF() async {
        guard let url = pdfURL, !saving else { return }
        saving = true
        let download = await webView.startDownload(using: URLRequest(url: url))
        download.delegate = self
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let pdf = Self.isPDF(navigationResponse.response)
        pdfURL = pdf ? navigationResponse.response.url : nil
        // A PDF the web view can't show (sent as an attachment) is downloaded, then offered to name.
        if pdf && !navigationResponse.canShowMIMEType { saving = true; return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { message = "Couldn't open that page: \(error.localizedDescription)" }
    }

    // MARK: WKUIDelegate

    /// Links that open a new window ("target=_blank", common for PDFs) open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard Self.isPDF(response) || suggestedFilename.lowercased().hasSuffix(".pdf") else {
            saving = false
            message = "That isn't a PDF, so it can't be added as a paper."
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(suggestedFilename.isEmpty ? "paper.pdf" : suggestedFilename)
        downloads[ObjectIdentifier(download)] = (file, file.lastPathComponent, response.url ?? download.originalRequest?.url)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        saving = false
        guard let d = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        defer { try? FileManager.default.removeItem(at: d.file.deletingLastPathComponent()) }
        guard let data = try? Data(contentsOf: d.file), data.starts(with: Data("%PDF".utf8)) else {
            message = "The site didn't send a PDF (it may want you to sign in first)."
            return
        }
        onFile?(data, d.name, d.source)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        saving = false
        downloads.removeValue(forKey: ObjectIdentifier(download))
        message = "Couldn't save that paper: \(error.localizedDescription)"
    }
}

#if os(iOS)
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

struct BoardBrowser: View {
    @Bindable var develop: DevelopModel
    let site: BoardSite
    @Environment(\.dismiss) private var dismiss
    @State private var browser: BoardBrowserState?
    @State private var naming: [DevelopModel.PendingUpload] = []
    @State private var added = 0

    var body: some View {
        Group {
            if let browser { page(browser) } else { ProgressView() }
        }
        .onAppear {
            guard browser == nil else { return }
            let made = BoardBrowserState(start: site.start)  // one web view for the browser's life
            made.onFile = { data, name, source in
                naming = [develop.pending(data, fileName: name, mime: "application/pdf", source: source ?? site.start)]
            }
            browser = made
        }
        .sheet(isPresented: Binding(get: { !naming.isEmpty }, set: { if !$0 { naming = [] } })) {
            NameUploadsSheet(develop: develop, uploads: $naming, onSave: { added += $0 })
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 640)
        #endif
    }

    private func page(_ state: BoardBrowserState) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.pdfURL == nil {
                    Text(site.hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                if let message = state.message {
                    Text(message)
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                WebViewHost(webView: state.webView)
            }
            .navigationTitle(state.title.isEmpty ? site.name : state.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") { state.webView.goBack() }.disabled(!state.canGoBack)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        state.message = nil
                        Task { await state.addCurrentPDF() }
                    } label: {
                        if state.saving { ProgressView().controlSize(.small) } else { Label("Add to Trove", systemImage: "plus.circle.fill") }
                    }
                    .disabled(state.pdfURL == nil || state.saving)
                    .help("Save this paper to your trove")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if added > 0 {
                    Text("\(added) paper\(added == 1 ? "" : "s") added to Your own papers")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
    }
}
