// Drives a Kabuk started with KABUK_DEBUG_DIR. Usage:
//   swift scripts/kabuk-debug.swift snapshot
//   swift scripts/kabuk-debug.swift type 'ls\r'
//   swift scripts/kabuk-debug.swift action splitRight:
//   swift scripts/kabuk-debug.swift dump | findquery apple | theme dracula
import Foundation
let args = CommandLine.arguments
let kind = args[1]
let object = args.count > 2 ? args[2].replacingOccurrences(of: "\\r", with: "\r") : nil
DistributedNotificationCenter.default().postNotificationName(.init("dev.kabuk.\(kind)"), object: object, userInfo: nil, deliverImmediately: true)
