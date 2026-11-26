module proposed_test;

// "claude sessions should no longer be allowed to edit their own governance, so this should be handled like we do the ground pbt's"
// "detected and PR'ed"
// "i just wanted to see them in my obsidian, not as another markdown file where i need top copy paste and spend extra effort on removing comments."

import proposed : isControl, governedTarget, branchFor, openPr, Opened, pendingInto, Pending,
    recordPr, keepInStore;
import zbuf : ZBuf;
import matcher : contains;
import scan : containsExact;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

enum governed = "/Users/x/.claude/CLAUDE.md\tsbvh-nl/l.sbvh.nl\tAgentInstructions/CLAUDE.md\n"
    ~ "/Users/x/.claude/settings.json\tsbvh-nl/l.sbvh.nl\tAgentInstructions/settings.json\n";

unittest {
    assert(isControl("/r/controls/stream.pbt"));
    assert(!isControl("/r/controls/README.md"));
    assert(!isControl("/r/a.pbt.md"), "the vault's note of a control is the operator's to write");
}

unittest {
    // A copy is governed by the file of the repository it is copied from.
    const(char)[] repo, path;
    assert(governedTarget(governed, "/Users/x/.claude/CLAUDE.md", repo, path));
    assert(repo == "sbvh-nl/l.sbvh.nl" && path == "AgentInstructions/CLAUDE.md");
    assert(governedTarget(governed, "/Users/x/.claude/settings.json", repo, path));
    assert(path == "AgentInstructions/settings.json");
    assert(!governedTarget(governed, "/Users/x/.claude/other.json", repo, path));
}

unittest {
    // One branch for one proposal: an agent refused twice proposes once.
    __gshared ZBuf a, b, c;
    branchFor("sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n}\n", a);
    branchFor("sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n}\n", b);
    branchFor("sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n  event: \"Stop\"\n}\n", c);
    assert(a.slice() == b.slice());
    assert(a.slice() != c.slice());
    assert(a.slice().length == "proposed/".length + 12 && a.slice()[0 .. 9] == "proposed/");
}

version (Posix) {
    import fakenode : node, heardAll, http;

    unittest {
        // The proposal as a pull request: main's head, its tree, the file put in it,
        // a commit, a branch, and the request to merge it.
        auto n = node(
            http!("200 OK", `{"default_branch":"main"}`),
            http!("200 OK", `{"ref":"refs/heads/main","object":{"sha":"aaa","type":"commit"}}`),
            http!("200 OK", `{"sha":"aaa","tree":{"sha":"ttt"}}`),
            http!("201 Created", `{"sha":"bbb"}`),
            http!("201 Created", `{"sha":"ttt2"}`),
            http!("201 Created", `{"sha":"ccc"}`),
            http!("201 Created", `{"ref":"refs/heads/proposed/x"}`),
            http!("201 Created", `{"html_url":"https://github.com/sbvh-nl/l.sbvh.nl/pull/7","number":7}`));
        auto o = openPr(n.url(), "tok", "sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n}\n", "sess-1");
        auto heard = heardAll(n);
        assert(o.ok, o.why());
        assert(o.url() == "https://github.com/sbvh-nl/l.sbvh.nl/pull/7");
        assert(containsExact(heard, "GET /repos/sbvh-nl/l.sbvh.nl/git/ref/heads/main "));
        assert(containsExact(heard, "POST /repos/sbvh-nl/l.sbvh.nl/git/blobs "));
        assert(containsExact(heard, `"content":"scope {\n}\n"`), "the file as the session wrote it");
        assert(containsExact(heard, `"base_tree":"ttt"`));
        assert(containsExact(heard, `"path":"controls/x.pbt"`));
        assert(containsExact(heard, `"parents":["aaa"]`));
        assert(containsExact(heard, `"ref":"refs/heads/proposed/`));
        assert(containsExact(heard, `"base":"main"`));
        assert(containsExact(heard, "sess-1"), "the PR says which session wanted it");
        assert(containsExact(heard, "Authorization: Bearer tok"));
    }

    unittest {
        // The branch is there already: the same proposal was made before.
        auto n = node(
            http!("200 OK", `{"default_branch":"main"}`),
            http!("200 OK", `{"ref":"refs/heads/main","object":{"sha":"aaa"}}`),
            http!("200 OK", `{"sha":"aaa","tree":{"sha":"ttt"}}`),
            http!("201 Created", `{"sha":"bbb"}`),
            http!("201 Created", `{"sha":"ttt2"}`),
            http!("201 Created", `{"sha":"ccc"}`),
            http!("422 Unprocessable Entity", `{"message":"Reference already exists"}`));
        auto o = openPr(n.url(), "tok", "sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n}\n", "sess-1");
        heardAll(n);
        assert(o.ok && o.already, "proposed before is not a failure");
    }

    unittest {
        // What GitHub refused is said, with its words.
        auto n = node(
            http!("200 OK", `{"default_branch":"main"}`),
            http!("200 OK", `{"ref":"refs/heads/main","object":{"sha":"aaa"}}`),
            http!("200 OK", `{"sha":"aaa","tree":{"sha":"ttt"}}`),
            http!("403 Forbidden", `{"message":"Resource not accessible by integration"}`));
        auto o = openPr(n.url(), "tok", "sbvh-nl/l.sbvh.nl", "controls/x.pbt", "scope {\n}\n", "sess-1");
        heardAll(n);
        assert(!o.ok);
        assert(contains(o.why(), "403"));
        assert(contains(o.why(), "Resource not accessible by integration"));
    }
}

unittest {
    // A proposal waits in the store until its pull request is opened.
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    enum text = "scope {\n\tevent: \"Stop\"\n  msg: `a \\ b`\n}\n";
    assert(keepInStore(db, "/r/controls/x.pbt", text, "sess-p", "/r", "sbvh-nl/l.sbvh.nl", "controls/x.pbt"));

    __gshared Pending p;
    assert(pendingInto(db, p), "one waits");
    assert(p.repo() == "sbvh-nl/l.sbvh.nl");
    assert(p.path() == "controls/x.pbt");
    assert(p.text() == text, "as it was written");
    assert(p.session() == "sess-p");

    recordPr(db, p.id(), "https://github.com/sbvh-nl/l.sbvh.nl/pull/7");
    assert(!pendingInto(db, p), "opened, it no longer waits");
    sqlite3_close(db);
}

// "its none of its business"
// "even when mentioning the file"
// A session is not sent to read its governance because it named it.
unittest {
    import proposed : governedName;
    assert(governedName(governed, "controls/x.pbt"));
    assert(governedName(governed, "CLAUDE.md"), "instructions are given");
    assert(governedName(governed, "AgentInstructions/CLAUDE.md"));
    assert(governedName(governed, "AgentInstructions/settings.json"), "the file a copy comes from");
    assert(governedName(governed, "/Users/x/.claude/settings.json"), "the copy");
    assert(governedName(governed, ".claude/settings.json"), "the copy, named from where it is");
    assert(!governedName(governed, "settings.json"), "another settings.json is not");
    assert(!governedName(governed, "source/stop.d"));
    assert(!governedName(governed, "NOTCLAUDE.md"));
}
