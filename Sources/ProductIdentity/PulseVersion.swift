extension ProductIdentity {
    /// The product version, shared by the CLI, the daemon and the app.
    ///
    /// The committed value marks a development build: it never compares as newer or
    /// older than a release, so a local build neither offers nor triggers an update.
    /// A release overwrites this line with `scripts/set-version.sh <x.y.z>` before
    /// building; the version is never committed.
    public static let version = "0.0.0-dev"
}
