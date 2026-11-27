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

// "right, to me it makes sense a session should know, but opportunistically,"
// 「[Opus 5.5] A session is told its ground when it is other than what it was last told, and only then.」
unittest {
    import standing : keepTold, toldOtherwise;
    import core.sys.posix.stdlib : mkdtemp, setenv, unsetenv;
    import core.stdc.stdlib : getenv, system;
    import db : mkdir;

    __gshared char[4096] was = 0;
    auto old = getenv("HOME");
    size_t ol = 0;
    if (old !is null) { while (old[ol] != 0) { was[ol] = old[ol]; ol++; } }
    __gshared char[64] home = "/tmp/ground-told-XXXXXX\0";
    assert(mkdtemp(home.ptr) !is null);
    __gshared char[128] qntx = 0;
    size_t hl = 0;
    while (home[hl] != 0) { qntx[hl] = home[hl]; hl++; }
    foreach (i, c; "/.qntx") qntx[hl + i] = c;
    assert(mkdir(qntx.ptr, 493) == 0);
    setenv("HOME", home.ptr, 1);

    enum machine = "ground 6be4de6 is active for this session: the machine's.";
    enum worktree = "ground v0.20.0-38 is active for this session: the ground installed in the worktree /w";
    assert(toldOtherwise("told-1", machine));   // never told
    keepTold("told-1", machine);
    assert(!toldOtherwise("told-1", machine));  // told this already
    assert(toldOtherwise("told-1", worktree));  // moved into a worktree
    keepTold("told-1", worktree);
    assert(!toldOtherwise("told-1", worktree));
    assert(toldOtherwise("told-1", machine));   // moved back
    assert(!toldOtherwise("../x", machine));    // an id that is no file name is never told

    if (ol > 0) setenv("HOME", was.ptr, 1); else unsetenv("HOME");
    __gshared char[128] rm = 0;
    size_t n = 0;
    foreach (c; "rm -rf ") rm[n++] = c;
    foreach (c; home[0 .. hl]) rm[n++] = c;
    rm[n] = 0;
    system(rm.ptr);
}
