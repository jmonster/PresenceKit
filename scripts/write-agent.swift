import Foundation
let args = CommandLine.arguments
if args.count < 3 { fatalError("Usage: write-agent.swift output.plist executable [arguments...]") }
let plist: [String: Any] = [
    "Label": "io.github.jmonster.PresenceAgent",
    "ProgramArguments": Array(args.dropFirst(2)),
    "RunAtLoad": true,
    "LimitLoadToSessionType": "Aqua"
]
let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
try data.write(to: URL(fileURLWithPath: args[1]), options: .atomic)
