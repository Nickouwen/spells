// footprint <pid> → "wall_ns footprint_bytes cpu_ns pkg_idle_wkups interrupt_wkups"
// Physical footprint (Activity Monitor's "Memory") + lifetime CPU via proc_pid_rusage:
// same uid, no sudo, no task port. Compiled by budget.sh with `swiftc -O`.
import Darwin

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: footprint <pid>\n", stderr)
    exit(64)
}
var ri = rusage_info_v4()
let rc = withUnsafeMutablePointer(to: &ri) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
}
guard rc == 0 else {
    perror("proc_pid_rusage(\(pid))")
    exit(1)
}
// ri_*_time is in mach ticks on Apple silicon; convert to ns.
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
let cpuNs = (ri.ri_user_time + ri.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
print(clock_gettime_nsec_np(CLOCK_REALTIME), ri.ri_phys_footprint, cpuNs, ri.ri_pkg_idle_wkups, ri.ri_interrupt_wkups)
