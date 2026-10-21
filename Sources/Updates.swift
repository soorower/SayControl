// Keeping the app current: Sparkle, started at launch, checking the feed in
// Info.plist (SUFeedURL) once a day.
//
// The feed is the appcast release.sh publishes next to the DMG; every entry
// in it is signed with the EdDSA key whose public half is SUPublicEDKey, so
// an update installs only if it was signed on the release Mac — whatever
// happens to the CDN in between. The build number Sparkle compares is
// CFBundleVersion, the commit count build.sh stamps in.
//
// The dev build runs the same updater against the same feed: its build
// number is never behind a release, so it is never offered one, and the
// owner sees exactly what a user sees. For trying an update end to end,
// `defaults write com.sayctrl.app.dev SUFeedURL http://localhost:8000/appcast.xml`
// points it at a local feed.
import Cocoa
import Sparkle

enum Updates {
    /// Started once, at launch. Holding the controller here keeps it alive for
    /// the life of the process; the updater schedules itself from then on.
    static let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)

    static var version: String {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        return "\(APP_VERSION) (\(build))"
    }
}
