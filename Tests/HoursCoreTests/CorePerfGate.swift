import Foundation

/// Wall-clock budgets flake on a loaded machine: perf tests always measure and print, but only
/// assert the budget with `HOURS_PERF=1`.
let perfEnforced = ProcessInfo.processInfo.environment["HOURS_PERF"] == "1"
