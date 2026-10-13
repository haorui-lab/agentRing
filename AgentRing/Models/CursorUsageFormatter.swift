//
//  CursorUsageFormatter.swift
//  Agent Ring
//
//  Resolves CursorPresentation label keys into localized UI copy.
//

import Foundation

enum CursorUsageFormatter {
    /// Resolve a presentation label key through the app localization table.
    static func localizedTitle(forKey key: String) -> String {
        L.localizedKey(key)
    }

    static func columnBrandName(from presentation: CursorPresentation) -> String {
        localizedTitle(forKey: presentation.columnBrandKey)
    }

    static func includedTitle(from presentation: CursorPresentation) -> String {
        localizedTitle(forKey: presentation.includedLabelKey)
    }

    static func secondaryTitle(from presentation: CursorPresentation) -> String? {
        guard let key = presentation.secondaryLabelKey else { return nil }
        return localizedTitle(forKey: key)
    }

    static func onDemandTitle(from presentation: CursorPresentation) -> String? {
        guard let key = presentation.onDemandLabelKey else { return nil }
        return localizedTitle(forKey: key)
    }

    /// Row title for the Smart LimitType pair (included / secondary-or-onDemand).
    static func rowTitle(for limitType: LimitType, presentation: CursorPresentation) -> String {
        switch limitType {
        case .cursorIncluded:
            return includedTitle(from: presentation)
        case .cursorOnDemand:
            if let secondary = secondaryTitle(from: presentation) {
                return secondary
            }
            if let onDemand = onDemandTitle(from: presentation) {
                return onDemand
            }
            return L.DetailRow.cursorOnDemand
        default:
            return limitType.detailDisplayName
        }
    }
}
