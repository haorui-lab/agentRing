//
//  SettingsView.swift
//  Agent Ring
//

import SwiftUI

/// 设置视图
/// 侧边栏布局：左侧标签导航 + 右侧内容区，对齐 macOS 13+ 系统设置风格
struct SettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var selectedTab: Int
    @StateObject private var localization = LocalizationManager.shared

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 188)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            Group {
                switch selectedTab {
                case 0:
                    GeneralSettingsView()
                case 1:
                    AuthSettingsView()
                case 2:
                    BluetoothSettingsView()
                case 3:
                    AboutView()
                default:
                    GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760)
        .frame(minHeight: 560, maxHeight: .infinity)
        .id(localization.updateTrigger)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 4) {
            // 顶部品牌区
            HStack(spacing: 10) {
                if let icon = ImageHelper.createAppIcon(size: 28) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .cornerRadius(7)
                }
                Text(L.App.name)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(SidebarTab.allCases) { tab in
                SidebarRow(
                    icon: tab.icon,
                    title: tab.title,
                    isSelected: selectedTab == tab.rawValue
                ) {
                    selectedTab = tab.rawValue
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Sidebar Tab

private enum SidebarTab: Int, CaseIterable, Identifiable {
    case general = 0, auth = 1, bluetooth = 2, about = 3

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .auth: return "key.horizontal"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return L.SettingsTab.general
        case .auth: return L.SettingsTab.auth
        case .bluetooth: return L.SettingsTab.bluetooth
        case .about: return L.SettingsTab.about
        }
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 22)
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Pins scroll content to the pane width so macOS radio/form controls
/// cannot inflate the hosting view and shove the sidebar off the window.
struct SettingsPaneScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding()
                    .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 预览
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
