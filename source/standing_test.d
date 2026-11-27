module standing_test;

// "to just take into account the worktree"
// "and make it clear that that ground is active for that worktree"

import standing : worktreeOf, worktreeOfProgram;

// 「[Opus 5.5] A program is a worktree's when it stands at <worktree>/.ground/bin/<name>.」
static assert(worktreeOfProgram("/w/ground-wt-x/.ground/bin/ground_hook") == "/w/ground-wt-x");
static assert(worktreeOfProgram("/Users/u/.local/bin/ground_hook") == "");
static assert(worktreeOfProgram("/nix/store/abc-ground/bin/ground") == "");
static assert(worktreeOfProgram("ground_hook") == "");
static assert(worktreeOfProgram("/.ground/bin/ground") == "");

// 「[Opus 5.5] The worktree a session stands in is the nearest tree up whose .git is a file; a checkout」
// 「[Opus 5.5] whose .git is a directory stands in no worktree, and neither does a place outside git.」
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import db : mkdir;
    import core.stdc.stdio : fopen, fputs, fclose;
    import core.stdc.stdlib : system;

    __gshared char[64] root = "/tmp/ground-standing-XXXXXX\0";
    assert(mkdtemp(root.ptr) !is null);
    size_t rl = 0;
    while (root[rl] != 0) rl++;
    __gshared char[256] p = 0;
    // 「[Opus 5.5] root ~ tail, as a C string in p」
    const(char)[] at(const(char)[] tail) {
        size_t n = 0;
        foreach (c; root[0 .. rl]) p[n++] = c;
        foreach (c; tail) p[n++] = c;
        p[n] = 0;
        return p[0 .. n];
    }
    foreach (d; ["/Ground-Code", "/Ground-Code/.git", "/Ground-Code/source",
                 "/ground-wt-x", "/ground-wt-x/source", "/ground-wt-x/source/sand", "/elsewhere"])
        assert(mkdir(at(d).ptr, 493 /* 0755 */) == 0);
    auto f = fopen(at("/ground-wt-x/.git").ptr, "w");
    assert(f !is null);
    fputs("gitdir: elsewhere\n", f);
    fclose(f);

    __gshared char[256] wt = 0;
    auto w = at("/ground-wt-x");
    foreach (i, c; w) wt[i] = c;
    auto wtPath = wt[0 .. w.length];

    __gshared char[4096] buf = 0;
    assert(worktreeOf(at("/ground-wt-x"), buf[]) == wtPath);
    assert(worktreeOf(at("/ground-wt-x/source/sand"), buf[]) == wtPath);
    assert(worktreeOf(at("/ground-wt-x/"), buf[]) == wtPath);
    assert(worktreeOf(at("/Ground-Code/source"), buf[]) == "");
    assert(worktreeOf(at("/Ground-Code"), buf[]) == "");
    assert(worktreeOf(at("/elsewhere"), buf[]) == "");
    assert(worktreeOf("", buf[]) == "");

    __gshared char[300] rm = 0;
    size_t n = 0;
    foreach (c; "rm -rf ") rm[n++] = c;
    foreach (c; root[0 .. rl]) rm[n++] = c;
    rm[n] = 0;
    system(rm.ptr);
}
