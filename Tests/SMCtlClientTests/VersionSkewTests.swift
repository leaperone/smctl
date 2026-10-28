import Testing
import SMCtlClient

@Test
func equalVersionsProduceNoAdvice() {
    #expect(VersionSkew.direction(client: "0.2.4", daemon: "0.2.4") == nil)
    #expect(VersionSkew.message(client: "0.2.4", daemon: "0.2.4") == nil)
}

@Test
func newerClientAsksToInstallTheHelper() throws {
    #expect(VersionSkew.direction(client: "0.2.4", daemon: "0.2.3") == .clientNewer)
    let message = try #require(VersionSkew.message(client: "0.2.4", daemon: "0.2.3"))
    #expect(message.contains("sudo smctl daemon install"))
}

@Test
func newerDaemonAsksToUpgradeTheClient() throws {
    // Reinstalling the helper from an older CLI would downgrade the daemon,
    // so the advice must point the other way.
    #expect(VersionSkew.direction(client: "0.2.3", daemon: "0.2.4") == .daemonNewer)
    let message = try #require(VersionSkew.message(client: "0.2.3", daemon: "0.2.4"))
    #expect(message.contains("brew upgrade smctl"))
    #expect(!message.contains("sudo smctl daemon install"))
}

@Test
func divergentVersionsDoNotGuessWhichSideIsNewer() throws {
    #expect(VersionSkew.direction(client: "dev", daemon: "0.2.4") == .divergent)
    let message = try #require(VersionSkew.message(client: "dev", daemon: "0.2.4"))
    #expect(message.contains("differ"))
}
