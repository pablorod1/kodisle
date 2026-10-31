import AppKit
import Foundation
import Observation

/// Tiny, safe expression evaluator (no NSExpression, which can raise on bad input).
/// Supports + - * / % ^, parentheses, decimals and unary minus.
enum Calc {
    static func evaluate(_ input: String) -> Double? {
        let normalized = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".")
        var parser = Parser(chars: Array(normalized))
        guard let value = parser.expression() else { return nil }
        parser.skipSpaces()
        guard parser.index == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        mutating func skipSpaces() { while index < chars.count, chars[index] == " " { index += 1 } }

        mutating func consume(_ c: Character) -> Bool {
            skipSpaces()
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                if consume("+") { guard let r = term() else { return nil }; value += r }
                else if consume("-") { guard let r = term() else { return nil }; value -= r }
                else { return value }
            }
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while true {
                if consume("*") { guard let r = power() else { return nil }; value *= r }
                else if consume("/") { guard let r = power() else { return nil }; value /= r }
                else if consume("%") { guard let r = power() else { return nil }; value = value.truncatingRemainder(dividingBy: r) }
                else { return value }
            }
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if consume("^") { guard let exp = power() else { return nil }; return pow(base, exp) }
            return base
        }

        mutating func unary() -> Double? {
            if consume("-") { return unary().map { -$0 } }
            if consume("+") { return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if consume("(") {
                guard let value = expression(), consume(")") else { return nil }
                return value
            }
            skipSpaces()
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            return Double(String(chars[start..<index]))
        }
    }
}

@MainActor @Observable
final class CalculatorModel {
    static let shared = CalculatorModel()
    var expression = ""
    private(set) var history: [(expr: String, result: String)] = []

    var result: String? { Calc.evaluate(expression).map(Fmt.number) }

    func commit() {
        guard let result else { return }
        history.insert((expression, result), at: 0)
        history = Array(history.prefix(8))
        expression = result
    }

    func clear() { expression = "" }
}

@MainActor @Observable
final class FocusTimer {
    static let shared = FocusTimer()
    enum Phase: String { case focus = "Focus", rest = "Break" }

    var phase: Phase = .focus
    private(set) var remaining: Int = 25 * 60
    private(set) var total: Int = 25 * 60
    private(set) var isRunning = false
    private(set) var completedSessions = 0
    @ObservationIgnored private var ticker: Timer?

    private init() { reset() }

    var progress: Double { total == 0 ? 0 : 1 - Double(remaining) / Double(total) }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        isRunning = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        isRunning = false
        ticker?.invalidate()
    }

    func reset() {
        pause()
        let minutes = phase == .focus ? AppSettings.shared.config.focusMinutes : AppSettings.shared.config.breakMinutes
        total = Int(minutes * 60)
        remaining = total
    }

    func switchPhase() {
        phase = phase == .focus ? .rest : .focus
        reset()
    }

    private func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 {
            if phase == .focus { completedSessions += 1 }
            NSSound(named: "Glass")?.play()
            KodisleStore.shared.post(KodisleEvent(symbol: "timer", title: "\(phase.rawValue) finished",
                                              subtitle: phase == .focus ? "Time for a break" : "Back to work",
                                              tint: .orange, widget: .timer))
            switchPhase()
        }
    }
}
