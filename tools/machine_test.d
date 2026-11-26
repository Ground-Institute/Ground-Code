module machine_test;

import machine : namesNode;

// A repository whose controls name the node, at the top level, is a machine's: its controls go only
// into its own machine's sand, never into a sand that declares it as a project.
static assert(namesNode("# k\nqntx {\n  url: \"http://10.88.0.2:8770\"\n}\n"));
static assert(namesNode("qntx{\n  url: \"x\"\n}\n"));

// A project's controls name no node: a qntx block nested in another, or none at all.
static assert(!namesNode("project {\n  qntx {\n    url: \"x\"\n  }\n}\n"));
static assert(!namesNode("scope {\n  event: \"PreToolUse\"\n}\n"));
static assert(!namesNode("# qntx {\n"));
static assert(!namesNode("qntxish {\n}\n"));

// "and i want to get rid of the symlink"
// 「[Fable 5.2] ground's own repository, declared as a project, is told by its origin: by the name it」
// 「[Fable 5.2] has and the name it had, and GitHub tells neither from the other by case.」
import machine : isGround;

static assert(isGround("Ground-Institute/Ground-Code"));
static assert(isGround("ground-institute/ground-code"));
static assert(isGround("teranos/ground"));
static assert(!isGround("Ground-Institute/laye"));
static assert(!isGround("teranos/ground-web"));
static assert(!isGround(""));
