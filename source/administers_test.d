module administers_test;

// "but laye owns people not ground, ground will always get it from laye"
// "its the story of someone verifying they can trust laye the network they are about to join, with their agent"

import proto : parsePbt;
import administers : administratorOf, askedAt, saysYes;
import zbuf : ZBuf;

enum parsed = parsePbt(`
person teranos {
}

org Ground-Institute {
  administrator: teranos
}

laye {
  url: "https://laye.ground.institute"
  org: Ground-Institute
}
`);

// 「[Fable 5.2] Who a pbt says administers its laye: the administrator of the org that governs it.」
static assert(administratorOf(parsed.orgs[0 .. parsed.orgCount], parsed.laye) == "teranos");

// 「[Fable 5.2] A laye no org governs, or whose org names nobody, has none said.」
enum bare = parsePbt("laye {\n  url: \"https://laye.example\"\n}\n");
static assert(administratorOf(bare.orgs[0 .. bare.orgCount], bare.laye) == "");
enum unnamed = parsePbt("org A {\n}\nlaye {\n  url: \"https://laye.example\"\n  org: A\n}\n");
static assert(administratorOf(unnamed.orgs[0 .. unnamed.orgCount], unnamed.laye) == "");

// 「[Fable 5.2] What laye is asked, at the laye the pbt names.」
unittest {
    ZBuf url;
    askedAt(url, "https://laye.ground.institute", "teranos");
    assert(url.slice() == "https://laye.ground.institute/laye/administrator/teranos");
    url.reset();
    askedAt(url, "https://laye.ground.institute/", "teranos");
    assert(url.slice() == "https://laye.ground.institute/laye/administrator/teranos");
}

// 「[Fable 5.2] laye's yes is the word true beside "administers", and nothing else is one.」
static assert(saysYes(`{"administrator":"teranos","administers":true}`));
static assert(saysYes(`{"administers": true, "administrator": "teranos"}`));
static assert(!saysYes(`{"administrator":"teranos","administers":false}`));
static assert(!saysYes(`{"administrator":"true"}`));
static assert(!saysYes(``));
