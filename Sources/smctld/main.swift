import Foundation
import SMCtlDaemonCore
import SMCtlProtocol

// The daemon is launched by launchd with no arguments. Reject anything else instead of
// silently starting a root daemon when someone (or a script) runs `smctld --version`.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") || arguments.contains("-v") {
    print(SMCtlProtocolInfo.version)
    exit(0)
}
if let unexpected = arguments.first {
    FileHandle.standardError.write(Data("""
    smctld: unexpected argument '\(unexpected)'
    smctld is a LaunchDaemon and takes no arguments. Manage it with:
      sudo smctl daemon install
      sudo smctl daemon restart
      sudo smctl daemon uninstall

    """.utf8))
    exit(64)
}

// Logic-free entry point: everything testable lives in SMCtlDaemonCore.
let daemon = SmctlDaemon()
daemon.start()
let listener = NSXPCListener(machServiceName: SMCtlProtocolInfo.machServiceName)
let delegate = ListenerDelegate(daemon: daemon)
listener.delegate = delegate
listener.resume()

// Graceful termination (launchctl bootout, system shutdown): restore hardware
// defaults before exiting so a stopped daemon never leaves charging disabled.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSignals = [SIGTERM, SIGINT].map { signalNumber in
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        smctldHandleTermination(daemon: daemon)
    }
    source.resume()
    return source
}
_ = terminationSignals

smctldLogStartupMode()
RunLoop.main.run()
