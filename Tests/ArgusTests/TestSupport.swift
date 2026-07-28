import Foundation
@testable import Argus

/// Builds a decoded HookEvent the way the hook script would emit it.
/// `term: nil` omits the field entirely, exercising the v1 log shape.
func event(_ name: String, _ detail: String = "", sid: String = "s1",
           cwd: String = "/tmp/proj", ppid: Int32 = 0, ts: Int = 1_785_217_000,
           iterm: String = "w0t0p0:AAA", term: String? = nil) -> HookEvent {
    let termField = term.map { ",\"term\":\"\($0)\"" } ?? ""
    let json = """
    {"v":2,"ts":\(ts),"event":"\(name)","detail":"\(detail)","session_id":"\(sid)",
     "cwd":"\(cwd)","transcript":"","iterm":"\(iterm)"\(termField),"ppid":\(ppid)}
    """
    return try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
}
