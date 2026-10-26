// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum UpdateSafety {
    /// Unknown inventory fails closed: replacing an active filesystem provider is unsafe.
    public static func shouldPostpone(mountInventory: String?, home: String) -> Bool {
        guard let mountInventory else { return true }
        return (try? ModuleSettings.hasActiveVolumes(mountInventory, home: home)) ?? true
    }
    public static func shouldReenable(previousBuild: String?, currentBuild: String, wasEnabled: Bool,
                                      moduleEnabled: Bool, activeVolumes: Bool) -> Bool {
        previousBuild != nil && previousBuild != currentBuild && wasEnabled && !moduleEnabled && !activeVolumes
    }
}
