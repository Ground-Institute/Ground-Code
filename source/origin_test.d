module origin_test;

// "FIX THE TYPED PATHS"
// "i dont want the quick fix asshole , i keep pushing for it"
// "is for those paths to also be homed no ?"
//
// 「[Fable 5.2] A scope, and a project's rituals and controls, name the repository they are for by」
// 「[Fable 5.2] its origin. No path fragment says where: what declares the repository says where it is.」

import proto : parsePbt;
import hooks : scopeMatchesAt, sameRepo;
import ritual.resolve : repoRoot;

// 「[Fable 5.2] A scope names a repository by its origin, and no path.」
enum scoped = parsePbt(`
scope {
  event: "Stop"
  origin: "Ground-Institute/Ground-Code"

  control {
    name: "ground-timing"
    timing: "true"
  }
}
`);
static assert(scoped.scopes[0].origin == "Ground-Institute/Ground-Code");
static assert(scoped.scopes[0].pathCount == 0);

// 「[Fable 5.2] GitHub tells no owner or repository from another by case.」
static assert(sameRepo("Ground-Institute/Ground-Code", "ground-institute/ground-code"));
static assert(!sameRepo("Ground-Institute/Ground-Code", "Ground-Institute/laye"));
static assert(!sameRepo("Ground-Institute/Ground-Code", ""));

// 「[Fable 5.2] It stands in every checkout of that repository, wherever it is and whatever its」
// 「[Fable 5.2] directory is called, and in no other.」
unittest {
    struct S { string[8] paths; ubyte pathCount; string origin; }
    S s;
    s.origin = "Ground-Institute/Ground-Code";
    assert(scopeMatchesAt(s, "/u/geology/ground-institute/Ground-Code/source",
                          "/u/geology/ground-institute/Ground-Code", "Ground-Institute/Ground-Code"));
    assert(scopeMatchesAt(s, "/u/anywhere/ground-wt-person", "/u/anywhere/ground-wt-person",
                          "ground-institute/ground-code"));
    assert(!scopeMatchesAt(s, "/u/geology/teranos/QNTX", "/u/geology/teranos/QNTX", "teranos/QNTX"));
    assert(!scopeMatchesAt(s, "/tmp", "", ""));

    // 「[Fable 5.2] A path said beside the origin still has to hold.」
    S both;
    both.origin = "teranos/QNTX";
    both.paths[0] = "/web";
    both.pathCount = 1;
    assert(scopeMatchesAt(both, "/u/geology/teranos/QNTX/web", "/u/geology/teranos/QNTX", "teranos/QNTX"));
    assert(!scopeMatchesAt(both, "/u/geology/teranos/QNTX/server", "/u/geology/teranos/QNTX", "teranos/QNTX"));

    // 「[Fable 5.2] A scope that names no origin is asked nothing of it.」
    S plain;
    assert(scopeMatchesAt(plain, "/tmp", "", ""));
}

enum rites = `
rites walk {
  ONE {
    eval: "true"
  }
}
`;

// 「[Fable 5.2] A project names its repository and no path. Its rituals are keyed on the origin,」
// 「[Fable 5.2] and where it is on disk is what the project declaring that origin with a place says.」
enum keyed = parsePbt(rites ~ `
project {
  path: "/home/u/geology/Ground-Institute/Ground-Code"
  origin: "Ground-Institute/Ground-Code"
}

project {
  origin: "Ground-Institute/Ground-Code"

  ritual jev {
    walk
  }
}
`);
static assert(keyed.rituals[0].projectPath == "Ground-Institute/Ground-Code");
static assert(keyed.projects[1].path == "Ground-Institute/Ground-Code");
static assert(repoRoot(keyed, keyed.rituals[0].projectPath) == "/home/u/geology/Ground-Institute/Ground-Code");

// 「[Fable 5.2] Where nothing declares that repository with a place, nothing says where it is.」
enum placeless = parsePbt(rites ~ `
project {
  origin: "a/b"

  ritual r {
    walk
  }
}
`);
static assert(repoRoot(placeless, placeless.rituals[0].projectPath) == "");

// 「[Fable 5.2] A control in such a project is that repository's, and no path decides.」
enum held = parsePbt(`
project {
  origin: "a/b"

  control {
    name: "x"
    event: "Stop"
    timing: "true"
  }
}
`);
static assert(held.ctrlPool[0].origin == "a/b");

// 「[Fable 5.2] A control carrying its own ritual, in a scope that names its repository and no path,」
// 「[Fable 5.2] performs in that repository.」
enum inlined = parsePbt(rites ~ `
scope {
  origin: "a/b"
  event: "PostToolUse"
  cmd: "echo held"

  control {
    name: "held"

    ritual {
      system: "s"

      walk
    }
  }
}
`);
static assert(inlined.rituals[0].name == "held");
static assert(inlined.rituals[0].projectPath == "a/b");
