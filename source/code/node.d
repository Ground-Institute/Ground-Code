module code.node;

// "so give it a config per ground per node"
// "you say the fix to this stupid situation is to eliminate competing source of truth and i agree with that."
//
// 「[Fable 5.2] The node ground code prompts through is the one every ground on this machine」
// 「[Fable 5.2] speaks to: the node of the most specific sand held, the comet's, else this」
// 「[Fable 5.2] machine's own (sand/layered.d). ground code is built from the floor, which names」
// 「[Fable 5.2] no node, and it read nodes.pbt for one while the sand beside it named another.」
// 「[Fable 5.2] nodes.pbt names the node where no sand held does, as it does for sky (nodeconfig.d).」
// 「[Fable 5.2] A sand hands its node over by itself (bin/sand.d), so ground code compiles none」
// 「[Fable 5.2] of the hooks to read it.」

import qntxblock : ParsedQntx, NODE_ABI;
import zbuf : ZBuf;

struct CodeNode {
    ParsedQntx node;
    // Why no node could be said: ground code stops on it.
    ZBuf said;
    // A sand that is there and was not read: said, and the others still stand.
    ZBuf noted;
    const(char)[] why() return { return said.slice(); }
    const(char)[] note() return { return noted.slice(); }
}

private size_t lengthOf(const(char)* s) {
    size_t n = 0;
    while (s[n] != 0) n++;
    return n;
}

// 「[Fable 5.2] The node the sand at path hands over. Null when nothing is at the path, and when」
// 「[Fable 5.2] what is there hands none over: then noted says why.」
private const(ParsedQntx)* nodeOfSand(const(char)* path, ref ZBuf noted) {
    import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_NOW, RTLD_LOCAL;
    import core.sys.posix.unistd : access, F_OK;
    if (access(path, F_OK) != 0) return null;
    void about() {
        if (noted.len > 0) noted.put("; ");
        noted.put(path[0 .. lengthOf(path)]);
        noted.put(": ");
    }
    // The library stays open for the life of the process: its node is read until exit.
    auto lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib is null) {
        about();
        noted.put("the sand did not load: ");
        auto e = dlerror();
        if (e !is null) noted.put(e[0 .. lengthOf(e)]);
        return null;
    }
    alias AbiFn = extern (C) ulong function();
    alias NodeFn = extern (C) const(ParsedQntx)* function();
    auto abi = cast(AbiFn) dlsym(lib, "ground_sand_node_abi");
    auto fn = cast(NodeFn) dlsym(lib, "ground_sand_node");
    if (abi is null || fn is null) {
        about();
        noted.put("the sand hands over no node: it was built by a ground from before a sand did");
        return null;
    }
    if (abi() != NODE_ABI) {
        about();
        noted.put("the sand's node was built for layout ");
        noted.putUint(abi());
        noted.put(", and this ground code reads layout ");
        noted.putUint(NODE_ABI);
        return null;
    }
    return fn();
}

void notRead(ref ZBuf noted, const(char)[] path) {
    if (noted.len > 0) noted.put("; ");
    noted.put(path);
    noted.put(" is there and is not read: the sand held names the node");
}

// 「[Fable 5.2] The node of the sands at these two places, the comet's before this machine's own;」
// 「[Fable 5.2] else the one node nodes.pbt names. An empty path is a sand that is not held.」
CodeNode nodeAt(const(char)[] local, const(char)[] comet) {
    import nodeconfig : NodeConfig, loadNodes;
    CodeNode r;
    __gshared char[1024] localZ = 0;
    __gshared char[1024] cometZ = 0;
    const(ParsedQntx)* top = null;
    if (local.length > 0 && local.length < localZ.length) {
        foreach (i, c; local) localZ[i] = c;
        localZ[local.length] = 0;
        auto held = nodeOfSand(localZ.ptr, r.noted);
        if (held !is null) top = held;
    }
    if (comet.length > 0 && comet.length < cometZ.length) {
        foreach (i, c; comet) cometZ[i] = c;
        cometZ[comet.length] = 0;
        auto held = nodeOfSand(cometZ.ptr, r.noted);
        if (held !is null) top = held;
    }
    if (top !is null && top.url.length > 0) {
        r.node = *top;
        // "really important to me that we eliminate competing truth source."
        // 「[Fable 5.2] A nodes.pbt beside a sand that names the node is a second place the node is」
        // 「[Fable 5.2] written, and is not read: said each time, until it is gone.」
        import nodeconfig : nodesPath;
        import core.sys.posix.unistd : access, F_OK;
        __gshared ZBuf z;
        z.reset();
        z.put(nodesPath());
        if (access(z.ptr(), F_OK) == 0) notRead(r.noted, nodesPath());
        return r;
    }

    __gshared NodeConfig nodes;
    loadNodes(nodes);
    if (nodes.why().length > 0) {
        r.said.put(nodes.why());
        return r;
    }
    if (nodes.count > 1) {
        r.said.put("ground code: nodes.pbt names more than one node, and which one ground code prompts through is not decided");
        return r;
    }
    if (nodes.count == 1) {
        r.node.present = true;
        r.node.url = cast(string) nodes.nodes[0].url;
        r.node.model = cast(string) nodes.nodes[0].model;
        r.node.gateway = cast(string) nodes.nodes[0].gateway;
    }
    return r;
}

// 「[Fable 5.2] The node of this process: the sand a turn names for itself or this machine's own,」
// 「[Fable 5.2] and the comet of the repository it stands in, as the hooks hold them (sand/load.d).」
CodeNode nodeOfCode() {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.unistd : getcwd;
    import comet : localSandPathInto, cometPathInto, namedSand;
    import git : originOf;
    __gshared char[1024] localBuf = 0;
    __gshared char[1024] cometBuf = 0;
    __gshared char[4096] cwdBuf = 0;
    auto homeZ = getenv("HOME");
    auto home = homeZ is null ? null : homeZ[0 .. lengthOf(homeZ)];
    const(char)[] local = namedSand();
    if (local.length == 0) local = localSandPathInto(home, localBuf[]);
    const(char)[] comet;
    if (getcwd(cwdBuf.ptr, cwdBuf.length) !is null)
        comet = cometPathInto(home, originOf(cwdBuf[0 .. lengthOf(cwdBuf.ptr)]), cometBuf[]);
    return nodeAt(local, comet);
}
