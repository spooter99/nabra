import AppKit

// Command-line modes (benchmarks, self-tests, remote control) run headless and exit; otherwise start the app.
if let index = CommandLine.arguments.firstIndex(of: "--remote"), index + 1 < CommandLine.arguments.count {
    exit(RemoteControl.send(CommandLine.arguments[index + 1]))
}
if CommandLineTool.shouldRun(arguments: CommandLine.arguments) {
    exit(CommandLineTool.run(arguments: CommandLine.arguments))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
