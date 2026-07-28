import Foundation
import Testing
@testable import Argus

@Suite struct GitTests {

    @Test func porcelainV2Parsing() {
        let full = GitStatus.parse("""
        # branch.oid abc
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 a b Sources/x.swift
        2 R. N... 100644 100644 100644 a b R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 a b c conflicted.swift
        ? untracked.txt
        """)
        #expect(full == GitState(dirty: 4, ahead: 2, behind: 1), "porcelain: dirty 4, +2 -1")

        let detached = GitStatus.parse("# branch.oid abc\n# branch.head (detached)\n? f.txt")
        #expect(detached == GitState(dirty: 1, ahead: nil, behind: nil),
                "porcelain: detached → no ahead/behind")

        #expect(GitStatus.parse("") == GitState(dirty: 0, ahead: nil, behind: nil),
                "porcelain: clean empty")
    }

    @Test func webURLDerivation() {
        #expect(GitStatus.webURL(remote: "git@github.com:acme/argus.git\n", branch: nil)?.absoluteString
                == "https://github.com/acme/argus", "webURL: ssh form")
        #expect(GitStatus.webURL(remote: "https://github.com/acme/argus.git", branch: "feat/x")?.absoluteString
                == "https://github.com/acme/argus/tree/feat/x", "webURL: https + branch")
        #expect(GitStatus.webURL(remote: "ssh://git@github.com:acme/r.git", branch: nil)?.absoluteString
                == "https://github.com/acme/r", "webURL: ssh:// prefix")
        #expect(GitStatus.webURL(remote: "", branch: nil) == nil, "webURL: empty → nil")
    }
}
