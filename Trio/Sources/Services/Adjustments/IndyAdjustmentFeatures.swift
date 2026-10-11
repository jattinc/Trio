import Combine
import CoreData
import Foundation
import SwiftUI
import Swinject
import UserNotifications

// dev-Indy additions, modelled on iAPS:
// - Hypo treatment: log carbs without a bolus and start a chosen override and/or temp target preset.
// - Override automation per preset: end with the next meal, end when glucose crosses a threshold,
//   and start a follow-on preset when the override ends on its own.
// - History: active adjustments, today's meal totals and a sensitivity/ISF/CR table.
//
// Everything lives in this one file, and its settings are kept in UserDefaults rather than the Core
// Data model, so the daily merge from upstream dev only ever meets a few one-line hooks.

// MARK: - Settings

/// Automation attached to one override preset, keyed by the preset's `id`.
struct OverrideAutomationRule: Codable, Equatable {
    var endWithNextMeal: Bool = false
    /// mg/dL; nil turns the check off.
    var endAboveGlucose: Decimal?
    /// mg/dL; nil turns the check off.
    var endBelowGlucose: Decimal?
    /// Preset started when this override ends on its own: duration, meal or glucose rule.
    var nextPresetID: String?

    var isEmpty: Bool {
        !endWithNextMeal && endAboveGlucose == nil && endBelowGlucose == nil && nextPresetID == nil
    }
}

final class IndyFeatureSettings {
    static let shared = IndyFeatureSettings()

    private enum Key {
        static let overrideRules = "indy.overrideAutomationRules"
        static let hypoOverridePresetID = "indy.hypoOverridePresetID"
        static let hypoTempTargetPresetID = "indy.hypoTempTargetPresetID"
    }

    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    var overrideRules: [String: OverrideAutomationRule] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Key.overrideRules),
              let rules = try? JSONDecoder().decode([String: OverrideAutomationRule].self, from: data)
        else { return [:] }
        return rules
    }

    func rule(forPresetID id: String) -> OverrideAutomationRule {
        overrideRules[id] ?? OverrideAutomationRule()
    }

    func setRule(_ rule: OverrideAutomationRule, forPresetID id: String) {
        var rules = overrideRules
        rules[id] = rule.isEmpty ? nil : rule
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Key.overrideRules)
        }
    }

    var hypoOverridePresetID: String? {
        get { defaults.string(forKey: Key.hypoOverridePresetID) }
        set { defaults.set(newValue, forKey: Key.hypoOverridePresetID) }
    }

    var hypoTempTargetPresetID: String? {
        get { defaults.string(forKey: Key.hypoTempTargetPresetID) }
        set { defaults.set(newValue, forKey: Key.hypoTempTargetPresetID) }
    }

    var isHypoTreatmentConfigured: Bool {
        hypoOverridePresetID != nil || hypoTempTargetPresetID != nil
    }
}

// MARK: - Override automation

/// Watches new glucose readings and carb entries and applies the active preset's automation rule.
/// All changes go through `AdjustmentManager`, so run entries, Nightscout upload and the
/// determination refresh happen exactly as for a Shortcut or watch command.
final class IndyOverrideAutomation: Injectable {
    static let shared = IndyOverrideAutomation()

    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!

    private var subscriptions = Set<AnyCancellable>()
    private var isStarted = false
    private var isEvaluating = false
    private let lock = NSLock()

    /// A follow-on preset only starts if the override ran out recently, so an override that expired
    /// while the app was not running does not start something hours later.
    private let followOnWindow: TimeInterval = 30 * 60

    private init() {}

    func start(resolver: Resolver) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true

        injectServices(resolver)
        glucoseStorage.updatePublisher
            .merge(with: carbsStorage.updatePublisher)
            .debounce(for: .seconds(3), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.evaluate() }
            }
            .store(in: &subscriptions)
    }

    // MARK: Hypo treatment

    /// Starts the configured hypo override and temp target presets. Returns the names started.
    @discardableResult func startHypoTreatmentAdjustments() async -> [String] {
        let settings = IndyFeatureSettings.shared
        var started: [String] = []

        if let presetID = settings.hypoOverridePresetID {
            do {
                let outcome = try await adjustmentManager.activateOverride(.presetID(presetID), source: .app)
                started.append(outcome.started?.name ?? String(localized: "Override"))
            } catch {
                debug(.service, "Hypo treatment: could not start override preset \(presetID): \(error)")
            }
        }

        if let presetID = settings.hypoTempTargetPresetID {
            do {
                let outcome = try await adjustmentManager.activateTempTarget(.presetID(presetID), source: .app)
                started.append(outcome.started?.name ?? String(localized: "Temp Target"))
            } catch {
                debug(.service, "Hypo treatment: could not start temp target preset \(presetID): \(error)")
            }
        }

        return started
    }

    // MARK: Evaluation

    private struct ActiveOverride {
        let presetID: String
        let name: String
        let start: Date
        let expiry: Date?
    }

    private struct Snapshot {
        let active: ActiveOverride
        let rule: OverrideAutomationRule
        let latestGlucose: Int?
        let mealSinceStart: Bool
    }

    private enum Decision {
        case cancel(reason: String)
        case startNext(presetID: String, reason: String)
    }

    private func beginEvaluation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isEvaluating else { return false }
        isEvaluating = true
        return true
    }

    private func endEvaluation() {
        lock.lock()
        isEvaluating = false
        lock.unlock()
    }

    private func evaluate() async {
        guard beginEvaluation() else { return }
        defer { endEvaluation() }

        let rules = IndyFeatureSettings.shared.overrideRules
        guard !rules.isEmpty else { return }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "IndyOverrideAutomation"
        let now = Date()

        let snapshot: Snapshot? = await context.perform {
            let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
            request.predicate = NSPredicate.lastActiveOverride
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1

            // Only presets carry rules; a custom override or an edited copy of a preset does not.
            guard let row = (try? context.fetch(request))?.first,
                  row.isPreset,
                  let presetID = row.id,
                  let rule = rules[presetID],
                  let start = row.date
            else { return nil }

            var expiry: Date?
            if !row.indefinite, let minutes = row.duration?.doubleValue, minutes > 0 {
                expiry = start.addingTimeInterval(minutes * 60)
            }

            // Latest reading taken after the override started.
            let glucoseRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            glucoseRequest.predicate = NSPredicate(format: "date > %@", start as NSDate)
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            glucoseRequest.fetchLimit = 1
            let latestGlucose = (try? context.fetch(glucoseRequest))?.first.map { Int($0.glucose) }

            // A meal is a real carb entry (not a fat/protein equivalent) dated after the start.
            var mealSinceStart = false
            if rule.endWithNextMeal {
                let carbRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
                carbRequest.predicate = NSPredicate(
                    format: "date > %@ AND date <= %@ AND isFPU == NO AND carbs > 0",
                    start as NSDate,
                    now.addingTimeInterval(5 * 60) as NSDate
                )
                carbRequest.fetchLimit = 1
                mealSinceStart = ((try? context.count(for: carbRequest)) ?? 0) > 0
            }

            let active = ActiveOverride(
                presetID: presetID,
                name: row.name ?? String(localized: "Override"),
                start: start,
                expiry: expiry
            )
            return Snapshot(active: active, rule: rule, latestGlucose: latestGlucose, mealSinceStart: mealSinceStart)
        }

        guard let snapshot,
              let decision = decide(
                  active: snapshot.active,
                  rule: snapshot.rule,
                  latestGlucose: snapshot.latestGlucose,
                  mealSinceStart: snapshot.mealSinceStart,
                  now: now
              )
        else { return }

        await apply(decision, to: snapshot.active)
    }

    private func decide(
        active: ActiveOverride,
        rule: OverrideAutomationRule,
        latestGlucose: Int?,
        mealSinceStart: Bool,
        now: Date
    ) -> Decision? {
        let reason: String
        if let expiry = active.expiry, expiry <= now {
            // Trio already treats an expired override as ended; only a follow-on needs action.
            guard rule.nextPresetID != nil, now.timeIntervalSince(expiry) <= followOnWindow else { return nil }
            reason = String(localized: "its duration ended")
        } else if rule.endWithNextMeal, mealSinceStart {
            reason = String(localized: "a meal was logged")
        } else if let above = rule.endAboveGlucose, let glucose = latestGlucose, Decimal(glucose) >= above {
            reason = String(localized: "glucose rose above \(above.formatted(withUnits: unitsForDisplay))")
        } else if let below = rule.endBelowGlucose, let glucose = latestGlucose, Decimal(glucose) <= below {
            reason = String(localized: "glucose fell below \(below.formatted(withUnits: unitsForDisplay))")
        } else {
            return nil
        }

        if let next = rule.nextPresetID, next != active.presetID {
            return .startNext(presetID: next, reason: reason)
        }
        return .cancel(reason: reason)
    }

    private func apply(_ decision: Decision, to active: ActiveOverride) async {
        do {
            switch decision {
            case let .cancel(reason):
                try await adjustmentManager.cancelOverride(source: .app)
                debug(.service, "Override automation: ended \"\(active.name)\" because \(reason)")
                notify(
                    title: String(localized: "Override Ended"),
                    body: String(localized: "\(active.name) ended because \(reason).")
                )
            case let .startNext(presetID, reason):
                let outcome = try await adjustmentManager.activateOverride(.presetID(presetID), source: .app)
                let nextName = outcome.started?.name ?? String(localized: "Override")
                debug(.service, "Override automation: \"\(active.name)\" ended because \(reason); started \"\(nextName)\"")
                notify(
                    title: String(localized: "Override Changed"),
                    body: String(localized: "\(active.name) ended because \(reason). Started \(nextName).")
                )
            }
        } catch {
            debug(.service, "Override automation failed for \"\(active.name)\": \(error)")
        }
    }

    private var unitsForDisplay: GlucoseUnits {
        (TrioApp.resolver.resolve(SettingsManager.self))?.settings.units ?? .mgdL
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "indy.overrideAutomation.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                debug(.service, "Override automation notification failed: \(error)")
            }
        }
    }
}

// MARK: - Glucose threshold helpers

private enum IndyGlucoseInput {
    static func range(for units: GlucoseUnits) -> ClosedRange<Double> {
        units == .mgdL ? 40 ... 400 : 2.2 ... 22.2
    }

    static func step(for units: GlucoseUnits) -> Double {
        units == .mgdL ? 1 : 0.1
    }

    static func display(_ mgdL: Decimal, units: GlucoseUnits) -> Double {
        Double(truncating: mgdL.asUnit(units) as NSNumber)
    }

    static func store(_ value: Double, units: GlucoseUnits) -> Decimal {
        let decimal = Decimal(value)
        return units == .mgdL ? Trio.rounded(decimal, scale: 0, roundingMode: .plain) : decimal.asMgdL
    }
}

// MARK: - Override preset automation editor

/// Shown in the override edit form for presets. Changes are saved as they are made.
struct OverrideAutomationSection: View {
    let presetID: String
    let units: GlucoseUnits

    @FetchRequest(
        entity: OverrideStored.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \OverrideStored.orderPosition, ascending: true)],
        predicate: NSPredicate.allOverridePresets
    ) private var presets: FetchedResults<OverrideStored>

    @State private var rule: OverrideAutomationRule

    init(presetID: String, units: GlucoseUnits) {
        self.presetID = presetID
        self.units = units
        _rule = State(initialValue: IndyFeatureSettings.shared.rule(forPresetID: presetID))
    }

    var body: some View {
        Section(
            header: Text("Automation"),
            footer: Text(
                "Saved as you change it. Checked with each new glucose reading and carb entry. Ending on glucose only uses readings taken after the override started. The follow-on preset also starts when the duration runs out."
            )
        ) {
            Toggle("End With Next Meal", isOn: $rule.endWithNextMeal)

            thresholdRow(
                title: String(localized: "End Above"),
                value: $rule.endAboveGlucose,
                defaultValue: 180
            )

            thresholdRow(
                title: String(localized: "End Below"),
                value: $rule.endBelowGlucose,
                defaultValue: 70
            )

            Picker("Then Start", selection: nextPresetBinding) {
                Text("Nothing").tag("")
                ForEach(presets.filter { $0.id != presetID }, id: \.objectID) { preset in
                    Text(preset.name ?? "").tag(preset.id ?? "")
                }
            }
        }
        .listRowBackground(Color.chart)
        .onChange(of: rule) { _, newRule in
            IndyFeatureSettings.shared.setRule(newRule, forPresetID: presetID)
        }
    }

    private var nextPresetBinding: Binding<String> {
        Binding(
            get: { rule.nextPresetID ?? "" },
            set: { rule.nextPresetID = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder private func thresholdRow(
        title: String,
        value: Binding<Decimal?>,
        defaultValue: Decimal
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? defaultValue : nil }
            )
        )

        if let current = value.wrappedValue {
            Stepper(
                value: Binding(
                    get: { IndyGlucoseInput.display(current, units: units) },
                    set: { value.wrappedValue = IndyGlucoseInput.store($0, units: units) }
                ),
                in: IndyGlucoseInput.range(for: units),
                step: IndyGlucoseInput.step(for: units)
            ) {
                Text(current.formatted(withUnits: units))
            }
        }
    }
}

// MARK: - Hypo treatment settings

/// Shown in Meal Settings.
struct HypoTreatmentSettingsSection: View {
    @FetchRequest(
        entity: OverrideStored.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \OverrideStored.orderPosition, ascending: true)],
        predicate: NSPredicate.allOverridePresets
    ) private var overridePresets: FetchedResults<OverrideStored>

    @FetchRequest(
        entity: TempTargetStored.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \TempTargetStored.orderPosition, ascending: true)],
        predicate: NSPredicate(format: "isPreset == %@", true as NSNumber)
    ) private var tempTargetPresets: FetchedResults<TempTargetStored>

    @State private var overridePresetID = IndyFeatureSettings.shared.hypoOverridePresetID ?? ""
    @State private var tempTargetPresetID = IndyFeatureSettings.shared.hypoTempTargetPresetID ?? ""

    var body: some View {
        Section(
            header: Text("Hypo Treatment"),
            footer: Text(
                "Choose an override and/or a temp target preset to enable the \"Log as Hypo Treatment\" button in Treatments. It logs the carbs without a bolus and starts the chosen presets."
            )
        ) {
            Picker("Override", selection: $overridePresetID) {
                Text("None").tag("")
                ForEach(overridePresets, id: \.objectID) { preset in
                    Text(preset.name ?? "").tag(preset.id ?? "")
                }
            }
            .onChange(of: overridePresetID) { _, newValue in
                IndyFeatureSettings.shared.hypoOverridePresetID = newValue.isEmpty ? nil : newValue
            }

            Picker("Temp Target", selection: $tempTargetPresetID) {
                Text("None").tag("")
                ForEach(tempTargetPresets, id: \.objectID) { preset in
                    Text(preset.name ?? "").tag(preset.id?.uuidString ?? "")
                }
            }
            .onChange(of: tempTargetPresetID) { _, newValue in
                IndyFeatureSettings.shared.hypoTempTargetPresetID = newValue.isEmpty ? nil : newValue
            }
        }
        .listRowBackground(Color.chart)
    }
}

// MARK: - Hypo treatment action

extension Treatments.StateModel {
    var showsHypoTreatmentButton: Bool {
        IndyFeatureSettings.shared.isHypoTreatmentConfigured && carbs > 0 && carbs <= maxCarbs && amount == 0
    }

    /// Starts the hypo presets, then logs the carbs without a bolus. Saving the carbs runs a
    /// determination, whose arrival closes the sheet as for a carbs-only entry.
    func invokeHypoTreatment() {
        Task {
            await MainActor.run {
                self.addButtonPressed = true
                self.amount = 0
                if self.note.isEmpty {
                    self.note = String(localized: "Hypo")
                }
            }

            await IndyOverrideAutomation.shared.startHypoTreatmentAdjustments()
            await saveMeal()
        }
    }
}

extension Treatments.RootView {
    @ViewBuilder var hypoTreatmentSection: some View {
        if state.showsHypoTreatmentButton {
            Section {
                Button {
                    state.invokeHypoTreatment()
                } label: {
                    HStack {
                        Image(systemName: "cross.case.fill")
                        Text("Log as Hypo Treatment")
                    }
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 35)
                }
                .disabled(state.addButtonPressed)
                .listRowBackground(state.addButtonPressed ? Color(.systemGray) : Color(.systemOrange))
                .shadow(radius: 3)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - History: active adjustments

/// Rows for the override and temp target that are running now; History otherwise lists only
/// finished runs.
struct HistoryActiveAdjustmentRows: View {
    let units: GlucoseUnits

    @FetchRequest(
        entity: OverrideStored.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \OverrideStored.date, ascending: false)],
        predicate: NSPredicate.lastActiveOverride
    ) private var overrides: FetchedResults<OverrideStored>

    @FetchRequest(
        entity: TempTargetStored.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \TempTargetStored.date, ascending: false)],
        predicate: NSPredicate.lastActiveTempTarget
    ) private var tempTargets: FetchedResults<TempTargetStored>

    var body: some View {
        let now = Date()
        let runningOverrides = overrides.filter {
            isRunning(start: $0.date, duration: $0.duration, indefinite: $0.indefinite, now: now)
        }
        let runningTempTargets = tempTargets.filter {
            isRunning(start: $0.date, duration: $0.duration, indefinite: false, now: now)
        }

        ForEach(runningOverrides, id: \.objectID) { row in
            activeRow(
                symbol: "clock.arrow.2.circlepath",
                color: .purple,
                name: row.name ?? String(localized: "Override"),
                detail: overrideDetail(row),
                start: row.date,
                end: endDate(start: row.date, duration: row.duration, indefinite: row.indefinite)
            )
        }

        ForEach(runningTempTargets, id: \.objectID) { row in
            activeRow(
                symbol: "target",
                color: .green,
                name: row.name ?? String(localized: "Temp Target"),
                detail: row.target.map { $0.decimalValue.formatted(withUnits: units) } ?? "",
                start: row.date,
                end: endDate(start: row.date, duration: row.duration, indefinite: false)
            )
        }
    }

    private func overrideDetail(_ row: OverrideStored) -> String {
        var parts = ["\(Int(row.percentage.rounded())) %"]
        if let target = row.target?.decimalValue, target != 0 {
            parts.append(target.formatted(withUnits: units))
        }
        return parts.joined(separator: ", ")
    }

    private func endDate(start: Date?, duration: NSDecimalNumber?, indefinite: Bool) -> Date? {
        guard !indefinite, let start, let minutes = duration?.doubleValue, minutes > 0 else { return nil }
        return start.addingTimeInterval(minutes * 60)
    }

    private func isRunning(start: Date?, duration: NSDecimalNumber?, indefinite: Bool, now: Date) -> Bool {
        guard let start, start <= now else { return false }
        if indefinite { return true }
        guard let end = endDate(start: start, duration: duration, indefinite: false) else { return false }
        return end > now
    }

    @ViewBuilder private func activeRow(
        symbol: String,
        color: Color,
        name: String,
        detail: String,
        start: Date?,
        end: Date?
    ) -> some View {
        let startText = start.map { Formatter.dateFormatter.string(from: $0) } ?? ""
        let endText = end.map { Formatter.dateFormatter.string(from: $0) } ?? String(localized: "indefinitely")

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(name)
                Spacer()
                Text("Active")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.25)))
            }
            Text([detail, "\(startText) - \(endText)"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - History: today's meals

/// Totals for entries dated since midnight. Fat/protein equivalents are left out so nothing is
/// counted twice.
struct TodaysMealsSummaryRow: View {
    @FetchRequest private var entries: FetchedResults<CarbEntryStored>

    init() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        _entries = FetchRequest(
            entity: CarbEntryStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: false)],
            predicate: NSPredicate(format: "date >= %@ AND isFPU == NO", startOfDay as NSDate)
        )
    }

    var body: some View {
        let now = Date()
        let today = entries.filter { ($0.date ?? .distantFuture) <= now }
        let carbs = today.reduce(0) { $0 + $1.carbs }
        let fat = today.reduce(0) { $0 + $1.fat }
        let protein = today.reduce(0) { $0 + $1.protein }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                Text(today.count == 1 ? String(localized: "1 entry") : String(localized: "\(today.count) entries"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                total(String(localized: "Carbs"), carbs, color: .loopYellow)
                total(String(localized: "Fat"), fat, color: .orange)
                total(String(localized: "Protein"), protein, color: .red)
            }
        }
    }

    @ViewBuilder private func total(_ label: String, _ grams: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").foregroundStyle(color).font(.caption2)
            Text(label).foregroundStyle(.secondary)
            Text("\(Int(grams.rounded())) g")
        }
        .font(.subheadline)
    }
}

// MARK: - History: sensitivity, ISF and CR per loop

struct HistoryRatiosList: View {
    let units: GlucoseUnits

    @FetchRequest private var determinations: FetchedResults<OrefDetermination>

    init(units: GlucoseUnits) {
        self.units = units
        _determinations = FetchRequest(
            entity: OrefDetermination.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \OrefDetermination.deliverAt, ascending: false)],
            predicate: NSPredicate(format: "deliverAt >= %@", Date.oneDayAgo as NSDate),
            animation: .default
        )
    }

    var body: some View {
        List {
            if determinations.isEmpty {
                ContentUnavailableView(
                    String(localized: "No data."),
                    systemImage: "function"
                )
            } else {
                averagesRow
                HStack {
                    Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Sens.").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("ISF").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("CR").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ForEach(determinations, id: \.objectID) { determination in
                    HStack {
                        Text(determination.deliverAt.map { Formatter.timeFormatterIndy.string(from: $0) } ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(ratioText(determination.sensitivityRatio?.decimalValue))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(isfText(determination.insulinSensitivity?.decimalValue))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(crText(determination.carbRatio?.decimalValue))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }
        }
        .listRowBackground(Color.chart)
    }

    private var averagesRow: some View {
        let ratios = determinations.compactMap { $0.sensitivityRatio?.decimalValue }
        let isfs = determinations.compactMap { $0.insulinSensitivity?.decimalValue }
        let crs = determinations.compactMap { $0.carbRatio?.decimalValue }

        return VStack(alignment: .leading, spacing: 4) {
            Text("24 h Average").font(.headline)
            HStack {
                Text("Sens. \(ratioText(average(ratios)))")
                Spacer()
                Text("ISF \(isfText(average(isfs)))")
                Spacer()
                Text("CR \(crText(average(crs)))")
            }
            .font(.subheadline)
            Text("ISF in \(units.rawValue)/U, CR in g/U")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func average(_ values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Decimal(values.count)
    }

    private func ratioText(_ value: Decimal?) -> String {
        guard let value else { return "–" }
        return "\(NSDecimalNumber(decimal: Trio.rounded(value * 100, scale: 0, roundingMode: .plain)).intValue) %"
    }

    private func isfText(_ value: Decimal?) -> String {
        guard let value else { return "–" }
        return units == .mgdL ? "\(NSDecimalNumber(decimal: Trio.rounded(value, scale: 0, roundingMode: .plain)).intValue)" :
            value.formattedAsMmolL
    }

    private func crText(_ value: Decimal?) -> String {
        guard let value else { return "–" }
        return Formatter.decimalFormatterWithOneFractionDigitIndy.string(from: value as NSNumber) ?? "\(value)"
    }
}

private extension Formatter {
    static let timeFormatterIndy: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let decimalFormatterWithOneFractionDigitIndy: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}
