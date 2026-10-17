import Foundation

@main
struct RuntimeHelperChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(condition(), "asynchronous operation completed")
    }

    static func main() {
        let samples = [
            "accessToken=secret-value",
            "refresh_token: secret-value",
            #"{"access_token":"secret-value","ok":true}"#,
            #"{"refresh_token": "secret-value"}"#,
            #"{'id_token':'secret-value'}"#,
            #"{"refreshToken":"secret-value","idToken":"secret-value"}"#,
            "Cookie: __Secure-next-auth.session-token.0=secret-value; other=keep",
            "https://example.com/?access_token=secret-value&next=keep",
            "Authorization: Bearer secret-value",
            #"{"Authorization":"Bearer secret-value"}"#,
            "ACCESS_TOKEN = secret-value"
        ]
        for sample in samples {
            let result = SensitiveDataRedactor.redactText(sample)
            expect(!result.contains("secret-value"), "redacts credential syntax: \(sample)")
            expect(result.contains("***REDACTED***"), "redaction marker is present")
            expect(SensitiveDataRedactor.redactText(result) == result, "redaction is idempotent")
        }
        let json = SensitiveDataRedactor.redactText(#"{"access_token":"secret-value","ok":true}"#)
        expect(json == #"{"access_token":"***REDACTED***","ok":true}"#, "JSON structure is preserved")
        let query = SensitiveDataRedactor.redactText("?access_token=secret-value&next=keep")
        expect(query.hasSuffix("&next=keep"), "adjacent query parameter is preserved")
        let ordinary = "no_access_token=keep myaccessToken=keep access_token_count=12 status=ok"
        expect(SensitiveDataRedactor.redactText(ordinary) == ordinary, "unrelated keys remain intact")

        let manager = TimerManager()
        var oldFires = 0
        var newFires = 0
        manager.schedule("replace", interval: 0.01) { oldFires += 1 }
        manager.schedule("replace", interval: 0.01, repeats: false) { newFires += 1 }
        pump { newFires == 1 }
        expect(oldFires == 0, "replacement invalidates old timer")
        expect(!manager.isActive("replace"), "one-shot timer is removed")

        var rescheduled = false
        manager.schedule("reuse", interval: 0.01, repeats: false) {
            manager.schedule("reuse", interval: 0.01, repeats: false) { rescheduled = true }
        }
        pump { rescheduled }
        expect(manager.activeTimers().isEmpty, "reentrant one-shot rescheduling cleans up")

        final class BackgroundState {
            var finished = false
            var fired = false
        }
        let background = BackgroundState()
        DispatchQueue.global().async {
            manager.schedule("background", interval: 0.01, repeats: false) {
                expect(Thread.isMainThread, "background-scheduled timer fires on main thread")
                background.fired = true
            }
            DispatchQueue.main.async { background.finished = true }
        }
        pump { background.finished && background.fired }

        var cancelledFired = false
        manager.schedule("cancel", interval: 0.01) { cancelledFired = true }
        manager.invalidateAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(!cancelledFired && manager.activeTimers().isEmpty, "invalidateAll prevents pending callbacks")
        print("All runtime helper checks passed.")
    }
}
