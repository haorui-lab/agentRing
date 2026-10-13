//
//  UsageDetailView.swift
//  Agent Ring
//

import SwiftUI
import UniformTypeIdentifiers

struct UsageDetailView: View {
    @Binding var codexUsageData: CodexUsageData?
    @Binding var cursorUsageData: CursorUsageData?
    @Binding var antigravityUsageData: AntigravityUsageData?
    @Binding var errorMessage: String?
    @Binding var codexNeedsRelogin: Bool
    @Binding var cursorNeedsRelogin: Bool
    @Binding var antigravityNeedsRelogin: Bool
    @ObservedObject var refreshState: RefreshState
    var onMenuAction: ((MenuAction) -> Void)? = nil
    @StateObject private var localization = LocalizationManager.shared
    @Binding var hasAvailableUpdate: Bool
    @Binding var shouldShowUpdateBadge: Bool

    enum LoadingAnimationType: Int, CaseIterable {
        case rainbow = 0
        case dashed = 1
        case pulse = 2

        var name: String {
            switch self {
            case .rainbow: return L.LoadingAnimation.rainbow
            case .dashed: return L.LoadingAnimation.dashed
            case .pulse: return L.LoadingAnimation.pulse
            }
        }
    }

    enum MenuAction {
        case generalSettings
        case authSettings
        case checkForUpdates
        case about
        case quit
        case refresh
        case codexRelogin
        case cursorRelogin
        case antigravityRelogin
    }

    @State var codexAnimationType: LoadingAnimationType = .rainbow
    @State var cursorAnimationType: LoadingAnimationType = .rainbow
    @State var antigravityAnimationType: LoadingAnimationType = .rainbow
    @State var rotationAngle: Double = 0
    @State var animationTimer: Timer?
    @State private var showAnimationTypeHint = false
    @State private var animationTypeHintName = ""
    @State private var animationTypeHintDismissWorkItem: DispatchWorkItem?
    @ObservedObject private var settings = UserSettings.shared
    private var showRemainingMode: Bool {
        settings.showRemainingMode
    }
    @State private var remainingModeAnimationTrigger = 0
    @State private var orderedProviders: [ProviderType] = []
    @State private var draggedProvider: ProviderType? = nil

    private var activeProviders: [ProviderType] {
        UserSettings.shared.orderedActiveProviders(
            codexUsageData: codexUsageData,
            cursorUsageData: cursorUsageData,
            antigravityUsageData: antigravityUsageData
        )
    }

    private var displayProviders: [ProviderType] {
        orderedProviders.isEmpty ? activeProviders : orderedProviders
    }

    private var providerColumnWidth: CGFloat {
        switch max(activeProviders.count, 1) {
        case 4...: return 245
        case 3: return 272
        case 2: return 276
        default: return 290
        }
    }

    private var showsMultipleProviders: Bool {
        activeProviders.count > 1
    }

    private var popoverWidth: CGFloat {
        switch activeProviders.count {
        case 4...: return 1040
        case 3: return 860
        case 2: return 580
        default: return 320
        }
    }

    private var activeDisplayTypes: [LimitType] {
        var types: [LimitType] = []
        if let codexUsageData {
            types.append(contentsOf: UserSettings.shared.getActiveCodexDisplayTypes(codexUsageData: codexUsageData))
        }
        if let cursorUsageData {
            types.append(contentsOf: UserSettings.shared.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData))
        }
        if let antigravityUsageData {
            types.append(contentsOf: UserSettings.shared.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravity))
            types.append(contentsOf: UserSettings.shared.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravityThird))
        }
        return types
    }

    private var contentSpacing: CGFloat {
        activeDisplayTypes.count >= 2 ? 10 : 16
    }

    private var contentHeight: CGFloat {
        // 多厂商时圆环上方多一行标题，底座加高，保证呼吸感与间距
        let baseHeight: CGFloat = showsMultipleProviders ? 222 : 190
        // 多列并排时高度应按「最高那一列」算，不能把各 provider 行数加总（会撑出大片空白）
        let maxRowsPerProvider = [
            UserSettings.shared.getActiveCodexDisplayTypes(codexUsageData: codexUsageData).count,
            UserSettings.shared.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData).count,
            UserSettings.shared.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravity).count,
            UserSettings.shared.getActiveAntigravityDisplayTypes(antigravityUsageData: antigravityUsageData, provider: .antigravityThird).count
        ].max() ?? 0
        let hasAnyData = codexUsageData != nil || cursorUsageData != nil || antigravityUsageData != nil
        let rowCount = max(maxRowsPerProvider, hasAnyData || !activeProviders.isEmpty ? 1 : 0)
        // 明细行高度与 UnifiedLimitRow 共用同一份 metrics，避免两边漂移
        return baseHeight + UnifiedLimitRowMetrics.textHeight(rowCount: rowCount)
    }

    private var providerDividerHeight: CGFloat {
        max(160, contentHeight - (showsMultipleProviders ? 52 : 40))
    }

    private var dashboardTitleText: String {
        let mode = showRemainingMode ? L.Usage.dashboardModeRemaining : L.Usage.dashboardModeUsed
        return L.Usage.dashboardTitle(appName: L.App.name, mode: mode)
    }

    private var headerView: some View {
        HStack {
            if showsMultipleProviders {
                Text(dashboardTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if let provider = activeProviders.first {
                switch provider {
                case .antigravity, .antigravityThird:
                    if let icon = ImageHelper.createAntigravityIcon(size: 18, isTemplate: false) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(providerTitle(for: provider))
                        .font(.headline)
                case .cursor:
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 16, weight: .semibold))
                    Text(L.Usage.cursorTitle)
                        .font(.headline)
                case .codex:
                    if let icon = ImageHelper.createCodexIcon(size: 18) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(L.Usage.codexTitle)
                        .font(.headline)
                }
            } else {
                Text(dashboardTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer()
            refreshAndMenuButtons
        }
        .frame(height: 20, alignment: .center)
        .padding(.horizontal)
        .padding(.top)
    }

    private var refreshAndMenuButtons: some View {
        HStack(spacing: 6) {
            Button(action: { onMenuAction?(.refresh) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(refreshState.isRefreshing ? rotationAngle : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!refreshState.canRefresh || refreshState.isRefreshing)
            .focusable(false)
            .help(L.Usage.refresh)

            ZStack(alignment: .topTrailing) {
                Button(action: { onMenuAction?(.generalSettings) }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(L.Menu.generalSettings)

                if shouldShowUpdateBadge {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if showsMultipleProviders {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(displayProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 {
                        ProviderDivider(height: providerDividerHeight)
                    }

                    draggableProviderColumn(for: provider)
                }
            }
            .padding(.horizontal, 8)
        } else if let singleProvider = activeProviders.first {
            providerColumn(for: singleProvider)
        } else if let errorMessage {
            errorState(
                message: errorMessage,
                needsRelogin: codexNeedsRelogin || cursorNeedsRelogin || antigravityNeedsRelogin,
                reloginAction: codexNeedsRelogin ? .codexRelogin : (cursorNeedsRelogin ? .cursorRelogin : .antigravityRelogin)
            )
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text(L.Usage.loading)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(height: 100)
        }
    }

    @ViewBuilder
    private func providerColumn(for provider: ProviderType) -> some View {
        VStack(spacing: 14) {
            if showsMultipleProviders {
                providerHeader(for: provider)
            }
            providerColumnBody(for: provider)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 拖动时原位卡片整体变为半透明（0.35），保持原始尺寸稳定，不拉伸相邻卡片；放下前目标位不插占位，松开才落位。
    @ViewBuilder
    private func draggableProviderColumn(for provider: ProviderType) -> some View {
        let isDragging = draggedProvider == provider
        providerColumn(for: provider)
            .opacity(isDragging ? 0.35 : 1.0)
            .contentShape(Rectangle())
            .onDrag {
                draggedProvider = provider
                return NSItemProvider(object: provider.rawValue as NSString)
            } preview: {
                providerColumn(for: provider)
                    .frame(width: providerColumnWidth)
                    .opacity(0.6)
                    .padding(8)
            }
            .onDrop(
                of: [UTType.text.identifier],
                delegate: ProviderDropDelegate(
                    item: provider,
                    providers: $orderedProviders,
                    draggedItem: $draggedProvider
                )
            )
    }

    private func providerHeader(for provider: ProviderType) -> some View {
        Text(providerTitle(for: provider))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .help(L.Usage.dragToReorder)
    }

    private func providerTitle(for provider: ProviderType) -> String {
        switch provider {
        case .codex: return L.Usage.codexTitle
        case .cursor:
            if let cursorUsageData {
                return CursorUsageFormatter.columnBrandName(from: cursorUsageData.presentation)
            }
            return L.Usage.cursorTitle
        case .antigravity: return L.Usage.antigravityTitle
        case .antigravityThird: return "Antigravity Third"
        }
    }

    @ViewBuilder
    private func providerColumnBody(for provider: ProviderType) -> some View {
        switch provider {
        case .codex:
            if let codexUsageData {
                CodexColumnView(
                    codexUsageData: codexUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    animationType: $codexAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: codexNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: codexNeedsRelogin,
                    reloginAction: .codexRelogin
                )
                .frame(maxWidth: .infinity)
            }
        case .cursor:
            if let cursorUsageData {
                CursorColumnView(
                    cursorUsageData: cursorUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    animationType: $cursorAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: cursorNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: cursorNeedsRelogin,
                    reloginAction: .cursorRelogin
                )
                .frame(maxWidth: .infinity)
            }
        case .antigravity:
            if let antigravityUsageData {
                AntigravityColumnView(
                    provider: .antigravity,
                    antigravityUsageData: antigravityUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    animationType: $antigravityAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: antigravityNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: antigravityNeedsRelogin,
                    reloginAction: .antigravityRelogin
                )
                .frame(maxWidth: .infinity)
            }
        case .antigravityThird:
            if let antigravityUsageData {
                AntigravityColumnView(
                    provider: .antigravityThird,
                    antigravityUsageData: antigravityUsageData,
                    showRemainingMode: showRemainingMode,
                    refreshState: refreshState,
                    animationType: $antigravityAnimationType,
                    rotationAngle: $rotationAngle,
                    remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                    onRefresh: { onMenuAction?(.refresh) },
                    onAnimationHint: { showAnimationHint($0) }
                )
                .frame(maxWidth: .infinity)
            } else {
                errorState(
                    message: antigravityNeedsRelogin ? L.Error.sessionExpired : (errorMessage ?? L.Usage.loading),
                    needsRelogin: antigravityNeedsRelogin,
                    reloginAction: .antigravityRelogin
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func errorState(message: String, needsRelogin: Bool, reloginAction: MenuAction = .codexRelogin) -> some View {
        VStack(spacing: 12) {
            Image(systemName: needsRelogin ? "lock.open.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if needsRelogin {
                Button(action: { onMenuAction?(reloginAction) }) {
                    Label(reloginButtonTitle(for: reloginAction), systemImage: "arrow.counterclockwise.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button(action: { onMenuAction?(.authSettings) }) {
                    Label(L.Usage.goToSettings, systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding()
    }

    private func reloginButtonTitle(for action: MenuAction) -> String {
        switch action {
        case .cursorRelogin: return L.Usage.cursorRelogin
        case .antigravityRelogin: return L.Usage.antigravityRelogin
        default: return L.Usage.codexRelogin
        }
    }

    private var animationHintView: some View {
        Group {
            if showAnimationTypeHint {
                AnimationTypeHintView(animationTypeName: animationTypeHintName)
                    .padding(.top, -8)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    var body: some View {
        VStack(spacing: contentSpacing) {
            VStack(spacing: contentSpacing) {
                headerView
                mainContent
            }
            .offset(y: showAnimationTypeHint ? -18 : 0)

            animationHintView
            Spacer()
        }
        .frame(width: popoverWidth, height: contentHeight)
        .animation(.easeInOut(duration: 0.25), value: showAnimationTypeHint)
        .id(localization.updateTrigger)
        .onAppear {
            orderedProviders = activeProviders
            if !UserDefaults.standard.bool(forKey: "ringShowsRemaining.defaultMigrated") {
                UserSettings.shared.showRemainingMode = true
                UserDefaults.standard.set(true, forKey: "ringShowsRemaining.defaultMigrated")
            }
            if refreshState.isRefreshing {
                startRotationAnimation()
            }
        }
        .onChange(of: activeProviders) { newProviders in
            if orderedProviders != newProviders && draggedProvider == nil {
                orderedProviders = newProviders
            }
        }
        .onChange(of: settings.showRemainingMode) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                remainingModeAnimationTrigger += 1
            }
        }
        .onHover { _ in
            if NSEvent.pressedMouseButtons == 0 && draggedProvider != nil {
                draggedProvider = nil
            }
        }
        .onChange(of: refreshState.isRefreshing) { newValue in
            newValue ? startRotationAnimation() : stopRotationAnimation()
        }
        .onDisappear {
            draggedProvider = nil
            stopRotationAnimation()
            animationTypeHintDismissWorkItem?.cancel()
        }
        #if DEBUG
        .background(UserSettings.shared.debugKeepDetailWindowOpen ? Color.white : Color.clear)
        #else
        .background(Color.clear)
        #endif
    }

    private func showAnimationHint(_ animationTypeName: String) {
        animationTypeHintDismissWorkItem?.cancel()
        animationTypeHintName = animationTypeName
        withAnimation(.easeInOut(duration: 0.25)) {
            showAnimationTypeHint = true
        }

        let dismissWorkItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) {
                showAnimationTypeHint = false
            }
        }
        animationTypeHintDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: dismissWorkItem)
    }
}

private struct ProviderDropDelegate: DropDelegate {
    let item: ProviderType
    @Binding var providers: [ProviderType]
    @Binding var draggedItem: ProviderType?

    func dropEntered(info: DropInfo) {
        // 悬停时不把被拖卡片插进目标位，避免半透明占位；只在松开时落位。
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItem = nil }

        if providers.isEmpty {
            providers = UserSettings.shared.orderedActiveProviders()
        }
        guard let currentDragged = draggedItem,
              currentDragged != item,
              let from = providers.firstIndex(of: currentDragged),
              let to = providers.firstIndex(of: item) else {
            return false
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            providers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            UserSettings.shared.setProviderOrder(providers)
        }
        return true
    }
}

private extension UsageDetailView {
    func startRotationAnimation() {
        stopRotationAnimation()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            rotationAngle += 3
            if rotationAngle >= 360 {
                rotationAngle = 0
            }
        }
    }

    func stopRotationAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

struct UsageDetailView_Previews: PreviewProvider {
    @State static var sampleCodexData: CodexUsageData? = CodexUsageData(
        primary: .init(percentage: 42, resetsAt: Date().addingTimeInterval(3600 * 2)),
        secondary: .init(percentage: 58, resetsAt: Date().addingTimeInterval(3600 * 24 * 3)),
        extraUsage: CodexExtraUsageData(
            hasCredits: true,
            unlimited: false,
            overageLimitReached: false,
            spendControlReached: false,
            balance: Decimal(12),
            approxLocalMessages: nil,
            approxCloudMessages: nil
        )
    )
    @State static var error: String?
    @State static var needsRelogin = false
    @State static var hasUpdate = false
    @State static var showBadge = false

    static var previews: some View {
        UsageDetailView(
            codexUsageData: $sampleCodexData,
            cursorUsageData: .constant(nil),
            antigravityUsageData: .constant(nil),
            errorMessage: $error,
            codexNeedsRelogin: $needsRelogin,
            cursorNeedsRelogin: .constant(false),
            antigravityNeedsRelogin: .constant(false),
            refreshState: RefreshState(),
            hasAvailableUpdate: $hasUpdate,
            shouldShowUpdateBadge: $showBadge
        )
    }
}
