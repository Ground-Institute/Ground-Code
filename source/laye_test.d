module laye_test;

// "its the story of someone verifying they can trust laye the network they are about to join, with their agent"
// "that laye itself laye ground institue itself has its own pbt governing itself, and you can see it on github, and that is what verified means"
// "Ground Institute would be governing laye.ground.institute"
// "but laye owns people not ground, ground will always get it from laye"
// "we do bans when we do bans, we do invites, when we do invites"

import proto : parsePbt, validateOrgs;
import count : countPbt;

enum src = `
person teranos {
}

org Ground-Institute {
  administrator: teranos
}

laye {
  url: "https://laye.ground.institute"
  org: Ground-Institute
}
`;
enum parsed = parsePbt(src);

static assert(parsed.personCount == 1);
static assert(parsed.people[0].name == "teranos");
static assert(parsed.orgs[0].name == "Ground-Institute");
static assert(parsed.orgs[0].administrator == "teranos");
static assert(parsed.laye.present);
static assert(parsed.laye.url == "https://laye.ground.institute");
static assert(parsed.laye.org == "Ground-Institute");
static assert(validateOrgs(parsed).text() == "");

// 「[Fable 5.2] Pass 1 walks the same text first.」
static assert(countPbt(src).totalProjects == 0);

// 「[Fable 5.2] An org that names no administrator has none.」
static assert(parsePbt("org A {\n}\n").orgs[0].administrator == "");

// 「[Fable 5.2] An org names a person that is there, and a laye an org that is there.」
enum nobody = parsePbt(`
org A {
  administrator: nobody
}
`);
static assert(validateOrgs(nobody).text() == "org A: no person named nobody");

enum ungoverned = parsePbt(`
laye {
  url: "https://laye.example"
  org: NOBODY
}
`);
static assert(validateOrgs(ungoverned).text() == "laye https://laye.example: no org named NOBODY");

// 「[Fable 5.2] A person is named and holds nothing; a laye says url: and org:, once.」
static assert(!__traits(compiles, { enum bad = parsePbt("person {\n}\n"); }));
static assert(!__traits(compiles, { enum bad = parsePbt("person a {\n  github: \"x\"\n}\n"); }));
static assert(!__traits(compiles, { enum bad = parsePbt("laye {\n  invite: true\n}\n"); }));
static assert(!__traits(compiles, { enum bad = parsePbt("laye {\n}\nlaye {\n}\n"); }));
