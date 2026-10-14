//
//  AuthSettingsView.swift
//  Agent Ring
//

import SwiftUI

struct AuthSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var selectedProvider: ProviderType = .codex
    @State private var isShowingToken = false
    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Account?
    @State private var isRecheckingAntigravity = false
    @State private var showDiagnostics = false

    var body: some View {
        SettingsPaneScroll {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $selectedProvider) {
                    Text("Codex").tag(ProviderType.codex)
                    Text("Cursor").tag(ProviderType.cursor)
                    Text("Antigravity").tag(ProviderType.antigravity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch selectedProvider {
                    case .codex:
                        providerAccountsCard(
                            accounts: settings.codexAccounts,
                            currentId: settings.currentCodexAccountId,
                            title: L.Account.codexAccounts,
                            addTitle: L.Account.addCodexAccount,
                            tokenLabel: "Codex Token",
                            onSelect: { settings.switchToCodexAccount($0) },
                            onAdd: { WebLoginWindowManager.shared.showCodexLoginWindow() },
                            onUpdateAlias: { settings.updateCodexAccount($0, alias: $1) }
                        )
                    case .cursor:
                        providerAccountsCard(
                            accounts: settings.cursorAccounts,
                            currentId: settings.currentCursorAccountId,
                            title: L.Account.cursorAccounts,
                            addTitle: L.Account.addCursorAccount,
                            tokenLabel: "Cursor Session",
                            onSelect: { settings.switchToCursorAccount($0) },
                            onAdd: { WebLoginWindowManager.shared.showCursorLoginWindow() },
                            onUpdateAlias: { settings.updateCursorAccount($0, alias: $1) }
                        )
                    case .antigravity, .antigravityThird:
                        antigravityCard
                    }
                }

                diagnosticsDisclosure
            }
        }
        .alert(L.Account.deleteConfirmTitle, isPresented: $showDeleteConfirmation) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.Account.delete, role: .destructive) {
                if let accountToDelete {
                    if accountToDelete.provider == .cursor {
                        settings.removeCursorAccount(accountToDelete)
                    } else {
                        settings.removeCodexAccount(accountToDelete)
                    }
                }
            }
        } message: {
            Text(L.Account.deleteConfirmMessage)
        }
        .onAppear {
            // 进入设置页：同步静默探测（不弹窗）
            refreshAntigravityCredentialStatus(allowInteractiveKeychain: false)
        }
        .onChange(of: settings.antigravityEnabled) { _ in
            refreshAntigravityCredentialStatus(allowInteractiveKeychain: false)
        }
        .onChange(of: selectedProvider) { _ in
            isShowingToken = false
        }
    }

    // MARK: - Provider accounts (Codex / Cursor)

    private func providerAccountsCard(
        accounts: [Account],
        currentId: UUID?,
        title: String,
        addTitle: String,
        tokenLabel: String,
        onSelect: @escaping (Account) -> Void,
        onAdd: @escaping () -> Void,
        onUpdateAlias: @escaping (Account, String?) -> Void
    ) -> some View {
        SettingCard(
            icon: "person.crop.circle",
            iconColor: .secondary,
            title: title,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text(L.Account.noAccounts)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(accounts) { account in
                        let isSelected = account.id == currentId
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                onSelect(account)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                        .font(.body)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        if let alias = account.alias, !alias.isEmpty {
                                            Text(account.accountName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isSelected {
                                accountDetailInline(
                                    account: account,
                                    tokenLabel: tokenLabel,
                                    onUpdateAlias: { onUpdateAlias(account, $0) }
                                )
                            }
                        }
                        .padding(.vertical, 6)

                        if account.id != accounts.last?.id {
                            Divider()
                        }
                    }
                }

                Button(action: onAdd) {
                    Label(addTitle, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
    }

    private func accountDetailInline(
        account: Account,
        tokenLabel: String,
        onUpdateAlias: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.Account.alias)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField(account.accountName, text: Binding(
                        get: { account.alias ?? "" },
                        set: { newValue in
                            onUpdateAlias(newValue.isEmpty ? nil : newValue)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    if let alias = account.alias, !alias.isEmpty {
                        Button {
                            onUpdateAlias(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L.Account.clearAlias)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(tokenLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    if isShowingToken {
                        Text(account.credentialToken)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(String(repeating: "•", count: min(account.credentialToken.count, 24)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        isShowingToken.toggle()
                    } label: {
                        Image(systemName: isShowingToken ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isShowingToken ? L.SettingsAuth.hidePassword : L.SettingsAuth.showPassword)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
            }

            Button(role: .destructive) {
                accountToDelete = account
                showDeleteConfirmation = true
            } label: {
                Label(L.Account.deleteAccount, systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Antigravity

    private var antigravityCard: some View {
        let statusText: String = {
            if !settings.antigravityEnabled {
                return L.Account.antigravityDisabled
            }
            if isRecheckingAntigravity {
                return L.Account.antigravityChecking
            }
            return settings.antigravityCredentialsPresent ? L.Account.antigravityReady : L.Account.antigravityMissing
        }()
        let statusColor: Color = {
            if !settings.antigravityEnabled || isRecheckingAntigravity { return .secondary }
            return settings.antigravityCredentialsPresent ? .green : .orange
        }()
        let statusIcon: String = {
            if !settings.antigravityEnabled { return "pause.circle" }
            if isRecheckingAntigravity { return "arrow.triangle.2.circlepath" }
            return settings.antigravityCredentialsPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }()

        return SettingCard(
            icon: "sparkles",
            iconColor: .secondary,
            title: L.Account.antigravityTitle,
            hint: L.Account.antigravityHint
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $settings.antigravityEnabled) {
                    Text(L.Account.antigravityEnableMonitoring)
                        .font(.subheadline)
                }
                .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L.Account.antigravityRecheck) {
                        refreshAntigravityCredentialStatus(allowInteractiveKeychain: true)
                        NotificationCenter.default.post(
                            name: .accountChanged,
                            object: nil,
                            userInfo: [Notification.UserInfoKey.provider: ProviderType.antigravity.rawValue]
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!settings.antigravityEnabled || isRecheckingAntigravity)
                }

                Text(L.Account.antigravitySourceHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Diagnostics (collapsed)

    private var diagnosticsDisclosure: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            DiagnosticsView()
                .padding(.top, 8)
        } label: {
            Label(L.Diagnostic.sectionTitle, systemImage: "stethoscope")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Helpers

    private func refreshAntigravityCredentialStatus(allowInteractiveKeychain: Bool = false) {
        isRecheckingAntigravity = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 始终同步刷新缓存；仅「重新检查」允许可能弹窗的 security CLI
            let present = AntigravityAPIService.credentialsAvailable(
                forceRefresh: true,
                allowInteractiveKeychain: allowInteractiveKeychain
            )
            DispatchQueue.main.async {
                settings.applyAntigravityCredentialsPresent(present)
                isRecheckingAntigravity = false
            }
        }
    }
}
