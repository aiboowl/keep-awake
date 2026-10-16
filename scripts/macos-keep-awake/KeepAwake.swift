import AppKit
import SwiftUI

struct CommandResult {
    let code: Int32
    let output: String
}

enum Controller {
    static var scriptURL: URL? {
        Bundle.main.url(forResource: "keep_awake", withExtension: "sh")
    }

    static func run(_ arguments: [String]) -> CommandResult {
        guard let script = scriptURL else {
            return CommandResult(code: 1, output: "В приложении отсутствует скрипт управления.")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(code: process.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(code: 1, output: error.localizedDescription)
        }
    }
}

struct PowerSnapshot {
    let idle: Bool
    let lid: Bool
    let ownsSetting: Bool
    let battery: String
    let charging: Bool
    let passwordless: Bool
    let ecoLimit: Int?
    let batteryGuard: Bool

    init?(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        guard lines.contains("SleepDisabled=0") || lines.contains("SleepDisabled=1") else {
            return nil
        }
        idle = output.contains("работает (caffeinate)")
        lid = lines.contains("SleepDisabled=1")
        ownsSetting = output.contains("Исходная настройка для stop:")
        charging = output.contains("'AC Power'")
        passwordless = lines.contains("Passwordless=1")
        ecoLimit = lines.first(where: { $0.hasPrefix("EcoLimit=") }).flatMap { Int($0.dropFirst(9)) }
        batteryGuard = lines.contains("BatteryGuard=1")
        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            battery = String(output[range])
        } else {
            battery = "—"
        }
    }
}

@MainActor
final class AwakeModel: ObservableObject {
    @Published var snapshot: PowerSnapshot?
    @Published var busy = false
    @Published var refreshing = false
    @Published var error: String?
    @Published var updatedAt: Date?
    private var timer: Timer?

    var fullMode: Bool { snapshot?.idle == true && snapshot?.lid == true }
    var canStop: Bool { snapshot?.idle == true || snapshot?.ownsSetting == true }
    var title: String {
        guard let state = snapshot else { return "Проверяем состояние…" }
        if state.ecoLimit != nil && !state.batteryGuard { return "Контроль батареи недоступен" }
        if fullMode && state.ecoLimit != nil { return "Экономный режим" }
        if fullMode { return "Mac не засыпает" }
        if state.idle { return "Защита с открытой крышкой" }
        if state.lid { return "Сон запрещён системой" }
        return "Обычный режим сна"
    }
    var subtitle: String {
        guard let state = snapshot else { return "Получаем текущие настройки Mac." }
        if state.ecoLimit != nil && !state.batteryGuard { return "Обновите состояние или включите эко-режим повторно." }
        if fullMode && state.ecoLimit == 100 { return "Mac работает от зарядки. Без неё разрешается сон." }
        if fullMode && state.ecoLimit == 20 { return "Mac не спит до 20% батареи, затем разрешается сон." }
        if fullMode { return "Включена защита и при закрытии крышки." }
        if state.idle { return "При закрытии крышки Mac может уснуть." }
        if state.lid { return "Запрет сна уже включён другой программой." }
        return "Включите защиту на время длительной работы."
    }

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // Hidden/inactive windows do not spawn shell processes on a timer.
            guard NSApplication.shared.isActive else { return }
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 15
    }

    func refresh(force: Bool = false) async {
        guard !refreshing && (!busy || force) else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await Task.detached { Controller.run(["status"]) }.value
        if result.code == 0, let state = PowerSnapshot(result.output) {
            snapshot = state
            updatedAt = Date()
        } else {
            snapshot = nil
            error = "Не удалось проверить настройки. Нажмите «Обновить»."
        }
    }

    func perform(_ arguments: [String]) {
        guard !busy else { return }
        busy = true
        error = nil
        let fullStart = arguments.first == "start" && !arguments.contains("--idle")
        let restoringLid = arguments.first == "stop" && snapshot?.lid == true && snapshot?.ownsSetting == true
        let needsSetup = (fullStart || restoringLid || arguments.first == "eco") && snapshot?.passwordless != true
        Task {
            // A status query in progress must finish before the next state update.
            while refreshing { try? await Task.sleep(nanoseconds: 50_000_000) }
            let result = await Task.detached {
                if needsSetup {
                    let setup = Controller.run(["setup"])
                    if setup.code != 0 { return setup }
                }
                return Controller.run(arguments)
            }.value
            if result.code != 0 {
                if arguments.first == "screen-off" {
                    error = "Не удалось выключить экран. Попробуйте ещё раз."
                } else if result.output.contains("-128") || result.output.localizedCaseInsensitiveContains("canceled") {
                    error = "Запрос администратора отменён. Состояние показано ниже."
                } else if result.output.contains("Другой запуск") {
                    error = "Другое переключение ещё выполняется. Завершите запрос macOS и повторите."
                } else {
                    error = "Не удалось переключить режим. Повторите попытку и подтвердите запрос macOS."
                }
            }
            await refresh(force: true)
            busy = false
        }
    }
}

struct StatusRow: View {
    let icon: String
    let title: String
    let active: Bool?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Label(active.map { $0 ? "Включена" : "Выключена" } ?? "Проверка",
                  systemImage: active.map { $0 ? "checkmark.circle.fill" : "minus.circle" } ?? "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active == true ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ControlView: View {
    @ObservedObject var model: AwakeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                    .flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 64, height: 64)))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Не засыпать").font(.system(size: 25, weight: .semibold))
                    Text("Управление сном Mac").foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.snapshot == nil ? Color.gray : model.fullMode ? Color.green : model.canStop ? Color.orange : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(model.title).font(.system(size: 18, weight: .semibold))
                }
                Text(model.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(spacing: 15) {
                    StatusRow(icon: "desktopcomputer", title: "Защита по бездействию", active: model.snapshot?.idle)
                    Divider()
                    StatusRow(icon: "laptopcomputer", title: "Закрытая крышка", active: model.snapshot?.lid)
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: model.snapshot?.charging == true ? "battery.100percent.bolt" : "battery.50percent")
                            .frame(width: 20).foregroundStyle(.secondary)
                        Text("Батарея")
                        Spacer()
                        Text(model.snapshot.map { "\($0.battery) · \($0.charging ? "на зарядке" : "без зарядки")" } ?? "—")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }

            VStack(spacing: 10) {
                HStack {
                    Button("Эко: только от зарядки") { model.perform(["eco", "--ac-only"]) }
                        .disabled(model.busy || model.snapshot == nil)
                    Button("Эко: до 20%") { model.perform(["eco", "20"]) }
                        .disabled(model.busy || model.snapshot == nil)
                }
                Text("При лимите снимается запрет сна. Во сне фоновые задачи приостановятся.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.snapshot?.ecoLimit != nil {
                    Button("Продолжать без лимита батареи") { model.perform(["start"]) }
                        .disabled(model.busy)
                }
                Button("Выключить экран") { model.perform(["screen-off"]) }
                    .disabled(model.busy || model.snapshot == nil)
                Button {
                    model.perform(model.fullMode ? ["stop"] : ["start"])
                } label: {
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.busy ? "Применяем настройку…" : model.fullMode ? "Вернуть обычный сон" : "Включить для закрытой крышки")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || model.snapshot == nil)
                .keyboardShortcut(.defaultAction)

                if !model.fullMode {
                    Button(model.canStop ? "Вернуть обычный сон" : "Только с открытой крышкой") {
                        model.perform(model.canStop ? ["stop"] : ["start", "--idle"])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.busy || model.snapshot == nil)
                }
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                if model.snapshot?.passwordless == true {
                    Label("Переключение без пароля настроено", systemImage: "checkmark.shield")
                } else {
                    Button("Настроить переключение без пароля") { model.perform(["setup"]) }
                        .buttonStyle(.link).disabled(model.busy || model.snapshot == nil)
                    Text("macOS запросит пароль один раз при настройке.")
                }
                Text("Для фоновых задач оставляйте нужные программы открытыми.")
                Text("Закрытие приложения не отключает режим.")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let date = model.updatedAt {
                    Text("Проверено в \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Обновить") {
                    model.error = nil
                    Task { await model.refresh() }
                }
                .buttonStyle(.link)
                .disabled(model.busy || model.refreshing)
            }
        }
        .padding(26)
        .frame(width: 458)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AwakeApp: App {
    @StateObject private var model = AwakeModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Не засыпать", id: "control") {
            ControlView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refresh() }
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            Text(model.title)
            Divider()
            Button("Открыть окно") {
                openWindow(id: "control")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button {
                model.perform(["screen-off"])
            } label: {
                Label("Выключить экран", systemImage: "display")
            }
            .help("Экран погаснет. Движение мыши или нажатие клавиши включит его снова.")
            .disabled(model.busy)
            Divider()
            Button("Эко: только от зарядки") { model.perform(["eco", "--ac-only"]) }
                .disabled(model.busy || model.snapshot == nil)
            Button("Эко: до 20% батареи") { model.perform(["eco", "20"]) }
                .disabled(model.busy || model.snapshot == nil)
            Button("Без лимита батареи") { model.perform(["start"]) }
                .disabled(model.busy || (model.fullMode && model.snapshot?.ecoLimit == nil) || model.snapshot == nil)
            Button("Вернуть обычный сон") { model.perform(["stop"]) }
                .disabled(model.busy || !model.canStop)
            if model.snapshot?.passwordless != true {
                Button("Настроить переключение без пароля") { model.perform(["setup"]) }
                    .disabled(model.busy || model.snapshot == nil)
            }
            Divider()
            Button("Закрыть приложение") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: model.fullMode ? "cup.and.saucer.fill" : "cup.and.saucer")
                .accessibilityLabel("Не засыпать: \(model.title)")
        }
    }
}

@main
enum EntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let result = Controller.run(["status"])
            guard result.code == 0, let state = PowerSnapshot(result.output) else {
                fputs(result.output, stderr)
                exit(1)
            }
            let report: [String: Any] = [
                "script": Controller.scriptURL!.path,
                "idleProtection": state.idle,
                "closedLidSetting": state.lid,
                "savedSetting": state.ownsSetting,
                "battery": state.battery,
                "passwordless": state.passwordless,
                "ecoLimit": state.ecoLimit as Any? ?? NSNull(),
                "batteryGuard": state.batteryGuard,
                "iconPresent": Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil,
            ]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        AwakeApp.main()
    }
}
