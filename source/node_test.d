module node_test;

import code.node : nodeAt, notRead;
import qntxblock : NODE_ABI;
import sand.builtin : hooksNode = qntxNode;
import comet : SAND_FILE;

// 「[Fable 5.2] ground code's node is the node the sand hands over: what the hooks read of the same」
// 「[Fable 5.2] controls, here the sand make sand built from this tree.」
unittest {
    auto found = nodeAt("build/" ~ SAND_FILE, "");
    assert(found.why().length == 0, found.why());
    assert(found.note().length == 0, found.note());
    assert(found.node.url == hooksNode.url && found.node.model == hooksNode.model
        && found.node.gateway == hooksNode.gateway, "the sand at build/ hands over another node than the hooks read");
}

// 「[Fable 5.2] The comet's node stands before this machine's own, and a sand that is not there is not held.」
unittest {
    auto found = nodeAt("build/no-such-sand", "build/" ~ SAND_FILE);
    assert(found.why().length == 0, found.why());
    assert(found.note().length == 0, found.note());
    assert(found.node.url == hooksNode.url);
}

// 「[Fable 5.2] What is there and is no sand is said, and stops nothing: nodes.pbt still names the node.」
unittest {
    import nodeconfig : nodesPath;
    import core.stdc.stdio : fopen, fputs, fclose;
    import zbuf : ZBuf;
    static void write(const(char)[] text) {
        ZBuf p;
        p.put(nodesPath());
        auto f = fopen(p.ptr(), "wb");
        assert(f !is null);
        ZBuf t;
        t.put(text);
        fputs(t.ptr(), f);
        fclose(f);
    }
    scope (exit) {
        import errors : unlink;
        ZBuf p;
        p.put(nodesPath());
        cast(void) unlink(p.ptr());
    }
    write("qntx {\n  url: \"https://a\"\n  model: \"m\"\n  gateway: \"https://g\"\n}\n");
    auto found = nodeAt("dub.json", "");
    assert(found.note().length > 0, "a file that is no sand is said");
    assert(found.why().length == 0, found.why());
    assert(found.node.url == "https://a" && found.node.model == "m" && found.node.gateway == "https://g");

    // 「[Fable 5.2] And nodes.pbt is read as it is for sky: a token in it is refused with its line.」
    write("qntx {\n  url: \"https://a\"\n  token: \"x\"\n}\n");
    auto refused = nodeAt("", "");
    assert(refused.why() == "nodes.pbt line 3: a qntx block holds url:, model: and gateway:, and token is none of them", refused.why());
}

// 「[Fable 5.2] A nodes.pbt beside a sand that names the node is said, and not read.」
unittest {
    import zbuf : ZBuf;
    ZBuf noted;
    notRead(noted, "/home/a/.local/share/ground/nodes.pbt");
    assert(noted.slice() == "/home/a/.local/share/ground/nodes.pbt is there and is not read: the sand held names the node");
}
