import Foundation
import SMCtlDaemonCore
import SMCtlProtocol

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
