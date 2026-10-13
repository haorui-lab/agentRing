//
//  CursorColumnView.swift
//  Agent Ring
//

import SwiftUI

struct CursorColumnView: View {
    let cursorUsageData: CursorUsageData
    let showRemainingMode: Bool
    let refreshState: RefreshState
    @Binding var animationType: UsageDetailView.LoadingAnimationType
    @Binding var rotationAngle: Double
    let remainingModeAnimationTrigger: Int
    var onRefresh: (() -> Void)?
    var onAnimationHint: ((String) -> Void)?

    private var activeTypes: [LimitType] {
        UserSettings.shared.getActiveCursorDisplayTypes(cursorUsageData: cursorUsageData)
    }

    private var isRefreshing: Bool {
        refreshState.isRefreshingProvider(.cursor)
    }

    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                if let included = cursorUsageData.included {
                    ActivityRingView(
                        outerPercentage: included.percentage,
                        innerPercentage: activeTypes.contains(.cursorOnDemand)
                            ? (cursorUsageData.secondary?.percentage ?? cursorUsageData.onDemand?.percentage)
                            : nil,
                        outerColor: UsageColorScheme.cursorIncludedColorSwiftUI(included.percentage),
                        innerColor: UsageColorScheme.cursorPairedInnerColorSwiftUI(
                            cursorUsageData.secondary?.percentage
                                ?? cursorUsageData.onDemand?.percentage
                                ?? 0
                        ),
                        isRefreshing: isRefreshing,
                        rotationAngle: rotationAngle,
                        showRemainingMode: showRemainingMode,
                        remainingModeAnimationTrigger: remainingModeAnimationTrigger,
                        animationType: animationType
                    )
                }
            }
            .frame(height: 114)
            .contentShape(Circle())
            .onTapGesture {
                if refreshState.canRefresh && !refreshState.isRefreshing {
                    onRefresh?()
                }
            }
            .onLongPressGesture(minimumDuration: 3.0) {
                let allTypes = UsageDetailView.LoadingAnimationType.allCases
                let currentIndex = allTypes.firstIndex(of: animationType) ?? 0
                animationType = allTypes[(currentIndex + 1) % allTypes.count]
                onAnimationHint?(animationType.name)
            }

            limitRows(for: activeTypes) { type in
                UnifiedLimitRow(
                    type: type,
                    cursorData: cursorUsageData,
                    showRemainingMode: showRemainingMode
                )
            }
            .padding(.horizontal, 10)
        }
    }
}
