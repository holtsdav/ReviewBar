import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    let model: AppModel
    @State private var showingCredentialForm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "rectangle.stack.badge.person.crop")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your App Store apps, at a glance")
                            .font(.largeTitle.bold())
                        Text("Track releases, reviews, builds, and TestFlight status without waiting for App Store Connect’s website.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFact(
                            symbol: "lock.shield",
                            title: "Private by design",
                            detail: "There is no ReviewBar account or backend. Requests go directly from this device to Apple."
                        )
                        OnboardingFact(
                            symbol: "key",
                            title: "Use an Apple API key",
                            detail: "Import the .p8 key Apple provides. ReviewBar stores its copy in this device’s Keychain."
                        )
                        OnboardingFact(
                            symbol: "arrow.down.circle",
                            title: "Works with cached data",
                            detail: "Previously loaded dashboards stay available when your connection doesn’t."
                        )
                    }

                    VStack(spacing: 12) {
                        Button("Connect to App Store Connect") {
                            showingCredentialForm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Button("Explore with Local Sample Data") {
                            Task { await model.enterDemo() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Opens ReviewBar with data stored in the app, without connecting to Apple")
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("ReviewBar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingCredentialForm) {
                CredentialFormView(model: model)
            }
        }
    }
}

private struct OnboardingFact: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CredentialFormView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: AppStoreConnectCredential.Scope = .individual
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var privateKeyPEM = ""
    @State private var importedFilename: String?
    @State private var showingImporter = false
    @State private var showingHelp = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Key type", selection: $scope) {
                        ForEach(AppStoreConnectCredential.Scope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Key ID", text: $keyID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if scope == .team {
                        TextField("Issuer ID", text: $issuerID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Apple API Key")
                } footer: {
                    Text(scope == .individual
                         ? "Individual keys inherit one App Store Connect user’s app access and are the recommended starting point."
                         : "Team keys use an issuer ID and apply across the team’s apps according to the key role.")
                }

                Section("Private Key") {
                    if let importedFilename {
                        Label {
                            Text(importedFilename).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                            .lineLimit(2)
                        Button("Replace Imported Key") { showingImporter = true }
                        Button("Remove Imported Key", role: .destructive) {
                            privateKeyPEM = ""
                            self.importedFilename = nil
                        }
                    } else {
                        Button("Import .p8 Private Key", systemImage: "doc.badge.plus") {
                            showingImporter = true
                        }
                    }
                    Text("ReviewBar never displays or uploads the key. Apple lets you download each .p8 file only once; keep the original somewhere secure.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Where do I find these values?", systemImage: "questionmark.circle") {
                        showingHelp = true
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isRefreshing {
                        ProgressView()
                            .accessibilityLabel("Testing connection")
                    } else {
                        Button("Test & Save") {
                            Task {
                                await connect()
                                if model.session == .ready {
                                    privateKeyPEM = ""
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!canConnect)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                importKey(result)
            }
            .alert("Couldn’t Import Key", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showingHelp) {
                CredentialHelpView()
            }
        }
        .interactiveDismissDisabled(model.isRefreshing)
    }

    private var canConnect: Bool {
        !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (scope == .individual || !issuerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !privateKeyPEM.isEmpty
            && !model.isRefreshing
    }

    private func connect() async {
        await model.connect(AppStoreConnectCredential(
            keyID: keyID,
            issuerID: scope == .team ? issuerID : nil,
            privateKeyPEM: privateKeyPEM,
            scope: scope
        ))
    }

    private func importKey(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                throw AppError(kind: .fileImport, message: "No file was selected.")
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16_384 else {
                throw AppError(kind: .fileImport, message: "Choose a .p8 private-key file smaller than 16 KB.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let pem = String(data: data, encoding: .utf8),
                  pem.components(separatedBy: "-----BEGIN PRIVATE KEY-----").count == 2,
                  pem.components(separatedBy: "-----END PRIVATE KEY-----").count == 2 else {
                throw AppError(kind: .fileImport, message: "That file does not contain one valid PKCS#8 private key.")
            }
            _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
            privateKeyPEM = pem
            importedFilename = url.lastPathComponent
        } catch {
            let mapped = AppError.map(error)
            importError = mapped.kind == .other ? "The selected file is not a valid App Store Connect .p8 private key." : mapped.message
        }
    }
}

private struct CredentialHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recommended: Individual Key") {
                    Text("First, the Account Holder requests API access in Users and Access → Integrations. After access is approved, an individual user opens their username, chooses Edit Profile, and creates an Individual API Key. A dedicated Developer-role user limited to the apps you need is a strong default.")
                }
                Section("Team Key") {
                    Text("An Account Holder or Admin can create a team key under Users and Access → Integrations. Team keys include an issuer ID and cannot be limited to selected apps.")
                }
                Section("Before Importing") {
                    Text("Apple provides the .p8 file only once. ReviewBar secures its imported copy in the iOS Keychain, but it cannot delete or protect the original file in Files.")
                }
            }
            .navigationTitle("API Key Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingView(model: .preview(session: .signedOut))
}
