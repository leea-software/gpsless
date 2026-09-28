import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share → GPSLess from Google Maps, Apple Maps or any app that shares a map
/// link or coordinates. The place is resolved here, then handed to the app
/// as gpsless://place?lat=…&lon=…; when iOS does not let the extension open
/// the app, the coordinates are copied for pasting in the app's search.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.openApp = { [weak self] url in
            return self?.openHostApp(url) ?? false
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task {
            await model.resolve(await sharedText())
        }
    }

    /// Links and text from the share sheet, joined so a place name shared
    /// next to its link is kept.
    private func sharedText() async -> String {
        var parts: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { item in
            return item.attachments ?? []
        }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                parts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                parts.append(text)
            }
        }
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Extensions have no UIApplication.shared; the app object is found on the
    /// responder chain and asked to open the link.
    private func openHostApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url, [:], nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State {
        case resolving
        case opened(SharedPlace)
        case copied(SharedPlace)
        case failed(String)
    }

    @Published var state: State = .resolving
    var finish: () -> Void = {}
    var openApp: (URL) -> Bool = { _ in
        return false
    }

    func resolve(_ text: String) async {
        do {
            let place = try await SharedPlaceResolver.resolve(text)
            if let url = SharedPlaceResolver.appURL(for: place), openApp(url) {
                state = .opened(place)
                try? await Task.sleep(for: .milliseconds(600))
                finish()
            } else {
                UIPasteboard.general.string = String(format: "%.6f, %.6f", place.latitude, place.longitude)
                state = .copied(place)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch model.state {
                case .resolving:
                    ProgressView()
                    Text("Finding the place…")
                        .foregroundStyle(.secondary)
                case .opened(let place):
                    placeSummary(place, symbol: "checkmark.circle.fill")
                    Text("Opening GPSLess…")
                        .foregroundStyle(.secondary)
                case .copied(let place):
                    placeSummary(place, symbol: "doc.on.clipboard.fill")
                    Text("Coordinates copied. Open GPSLess, tap Search and then Paste.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(reason)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("GPSLess")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.finish()
                    }
                }
            }
        }
    }

    private func placeSummary(_ place: SharedPlace, symbol: String) -> some View {
        return VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(place.name ?? "Shared place")
                .font(.headline)
            Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
