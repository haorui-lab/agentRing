//
//  TimerManager.swift
//  Agent Ring
//

import Foundation

/// 定时器统一管理器
/// 负责应用内所有定时器的创建、调度和清理，防止内存泄漏
/// 提供类型安全的定时器标识符管理
class TimerManager {
    // MARK: - Properties

    /// 定时器存储字典，键为标识符，值为 Timer 实例
    private var timers: [String: Timer] = [:]

    /// Timer 和 RunLoop 的操作统一在主线程串行执行。
    /// 后台调用会同步切到主线程，调用方不应阻塞主线程等待它完成。
    private func onMain<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }

    /// 替换同名定时器，并加入主 RunLoop 的 common modes，避免菜单交互暂停刷新。
    func schedule(
        _ identifier: String,
        interval: TimeInterval,
        repeats: Bool = true,
        block: @escaping () -> Void
    ) {
        onMain {
            timers.removeValue(forKey: identifier)?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] firedTimer in
                guard let self, self.timers[identifier] === firedTimer else { return }
                if !repeats {
                    self.timers.removeValue(forKey: identifier)
                }
                // 先移除单次定时器，允许回调安全地用同一标识重新调度。
                block()
            }
            timers[identifier] = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func invalidate(_ identifier: String) {
        onMain {
            timers.removeValue(forKey: identifier)?.invalidate()
        }
    }

    func invalidateAll() {
        onMain {
            timers.values.forEach { $0.invalidate() }
            timers.removeAll()
        }
    }

    func isActive(_ identifier: String) -> Bool {
        onMain { timers[identifier]?.isValid ?? false }
    }

    func activeTimers() -> [String] {
        onMain { timers.keys.filter { timers[$0]?.isValid == true } }
    }

    // MARK: - Deinit

    deinit {
        invalidateAll()
    }
}

// MARK: - Timer Identifiers

/// 定时器标识符命名空间
/// 提供类型安全的定时器标识符常量
extension TimerManager {
    /// 定时器标识符枚举
    enum Identifier {
        /// 主数据刷新定时器
        static let mainRefresh = "mainRefresh"
        /// 弹出窗口实时刷新定时器（1秒间隔）
        static let popoverRefresh = "popoverRefresh"
        /// 重置验证定时器 - 重置后1秒
        static let resetVerify1 = "resetVerify1"
        /// 重置验证定时器 - 重置后10秒
        static let resetVerify2 = "resetVerify2"
        /// 重置验证定时器 - 重置后30秒
        static let resetVerify3 = "resetVerify3"
        /// 每日更新检查定时器
        static let dailyUpdate = "dailyUpdate"
        /// Codex accessToken 主动续期定时器（独立于用量拉取计时器）
        static let codexTokenRefresh = "codexTokenRefresh"
    }
}
