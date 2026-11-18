import Foundation

/// 0.23.0 (Bohdan 18.11): a new version opens the update window on every launch, once per launch and version, and only
/// when nothing else comes first: not before the sign-in or the onboarding, not over What's new, never during a call.
/// "Later" in the window closes it for this launch; "Later" on Home's banner hides the banner and the window too, until
/// the next launch (UpdateService.later). Checked in CoreChecks (updatePromptR).
public enum UpdatePrompt {
    public static func shouldShow(newVersion: String?, shownThisLaunch: Set<String>, signedIn: Bool, onboarded: Bool,
                                  callLive: Bool, otherWindowUp: Bool) -> Bool {
        guard let v = newVersion, !v.isEmpty else { return false }
        return signedIn && onboarded && !callLive && !otherWindowUp && !shownThisLaunch.contains(v)
    }
}
