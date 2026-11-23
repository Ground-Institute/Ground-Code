module keepcmd;

// ground keep: every line of every transcript under ~/.claude/projects, main and
// subagent, and under ~/.codex/sessions, kept as an attestation for the sky to stream to the node; then what
// was kept, file by file against its bytes on disk. Exit 1 when a file's lines
// were not all kept, or what was kept is not what the file holds.
// "i dont want to come back, and find out i missed something"

import core.stdc.stdio : stderr, stdout, fputs, fprintf;

enum BOOK_COMMAND = q"EOS
# every transcript's lines kept, and each file checked against what was kept:
ground keep
# what is kept sent to a node reached directly, the primary signing and carrying none of it:
ground keep send http://k.tail.sbvh.nl:8770
EOS";

// "q signs, data direct"
// ground keep send <node>: the kept lines to the node named, from where each
// file was last sent up to, for a minute; the stream's node signs (direct.d).
int handleKeepSend(const(char)[] node) {
    import direct : sendDirect;
    import nodeconfig : nodeHere;
    import transcript : transcriptRoots;
    auto here = nodeHere();
    if (here.url.length == 0) { fputs("ground keep send: this ground streams to no node, so nobody signs\n", stderr); return 1; }
    auto roots = transcriptRoots();
    if (roots.length == 0) { fputs("ground keep send: no HOME, so no ~/.claude/projects or ~/.codex/sessions\n", stderr); return 1; }
    import direct : rememberDirectNode, restDirect;
    import core.stdc.time : time;
    rememberDirectNode(node);
    auto s = sendDirect(here.url, node, roots, 60);
    if (s.busy || s.halt) restDirect(cast(long) time(null));
    fprintf(stdout, "ground keep send: %lld lines of %lld files sent to %.*s, %lld files stopped at a line it refused\n",
            s.rows, s.files, cast(int) node.length, node.ptr, s.stuck);
    fprintf(stdout, "ground keep send: largest batch %lld lines, slowest answer %lld ms (signing %lld ms, the node %lld ms)\n",
            s.mostRows, s.slowestUs / 1000, s.slowestSignUs / 1000, s.slowestPostUs / 1000);
    if (s.busy) {
        fputs("ground keep send: busy: the node was slow over a batch, and is left alone\n", stderr);
        return 2;
    }
    if (!s.ok) {
        fprintf(stderr, "ground keep send: stopped: %.*s\n", cast(int) s.why().length, s.why().ptr);
        return 1;
    }
    return 0;
}

int handleKeep() {
    import db : openDb, sqlite3_close;
    import transcript : keepAll, transcriptRoots, provenAll;

    auto db = openDb();
    if (db is null) { fputs("ground keep: the store would not open\n", stderr); return 1; }
    scope (exit) sqlite3_close(db);

    auto roots = transcriptRoots();
    if (roots.length == 0) { fputs("ground keep: no HOME, so no ~/.claude/projects or ~/.codex/sessions\n", stderr); return 1; }

    auto swept = keepAll(db, roots);
    fprintf(stdout, "ground keep: %zu files, %zu lines kept now, %zu files not kept\n",
            swept.files, swept.lines, swept.failed);

    auto proof = provenAll(db, roots);
    fprintf(stdout, "ground keep: %zu files hold exactly what was kept, %zu do not\n",
            proof.same, proof.differ);
    foreach (i; 0 .. proof.shown)
        fprintf(stderr, "ground keep: differs: %.*s\n", cast(int) proof.paths[i].length, proof.paths[i].ptr);

    return swept.ok && proof.differ == 0 ? 0 : 1;
}
