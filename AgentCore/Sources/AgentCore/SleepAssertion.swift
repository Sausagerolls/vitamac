import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that keeps the Mac (and its display) awake
/// while the agent is serving. Without it, idle display/system sleep would
/// suspend the agent and drop the paired iPhone's connection — so the app
/// looks like it "closed". Acquired when the listener is ready, released when
/// the server tears down, so the Mac sleeps normally once the agent stops.
final class SleepAssertion {
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    private var held = false

    /// Prevents idle display sleep (which implicitly keeps the system awake too).
    func acquire(reason: String = "VitaMac Agent is sharing this Mac's activity") {
        guard !held else { return }
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        if result == kIOReturnSuccess {
            id = assertionID
            held = true
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(0)
        held = false
    }

    deinit { release() }
}
