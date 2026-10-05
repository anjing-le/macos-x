/// A transient AX read failure cannot erase a verified focus, but a foreground
/// app change, closed window or off-screen window invalidates that fallback.
public enum WindowFocusResolution {
    public static func resolve(observed: UInt32?, confirmed: UInt32?, foregroundPID: Int32?,
                               owners: [UInt32: Int32], visibleIDs: Set<UInt32>) -> UInt32? {
        for candidate in [observed, confirmed] {
            if let id = candidate, let pid = foregroundPID,
               owners[id] == pid, visibleIDs.contains(id) { return id }
        }
        return nil
    }
}
