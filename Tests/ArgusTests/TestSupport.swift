import Foundation
@testable import Argus

/// Builds a decoded HookEvent the way the hook script would emit it.
func event(_ name: String, _ detail: String = "", sid: String = "s1",
           cwd: String = "/tmp/proj", ppid: Int32 = 0, ts: Int = 1_785_217_000) -> HookEvent {
    let json = """
    {"v":1,"ts":\(ts),"event":"\(name)","detail":"\(detail)","session_id":"\(sid)",
     "cwd":"\(cwd)","transcript":"","iterm":"w0t0p0:AAA","ppid":\(ppid)}
    """
    return try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
}
