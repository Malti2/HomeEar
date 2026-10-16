import Foundation

/// A daily time window in which the microphone is paused automatically.
/// Whole hours only; the window may wrap past midnight (23 → 7).
struct QuietHours: Equatable {
    var startHour: Int
    var endHour: Int

    /// Equal start and end mean "no window", not "all day".
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }
}
