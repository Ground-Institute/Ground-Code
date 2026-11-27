module sand_entry;

// "only the compiled controls being their own thing shipped to the user"

// The sand alone, for an engine to load: the controls this was compiled with, and nothing that runs them.
import sand.view : Sand;
import sand.builtin : builtinSand;

extern (C) export const(Sand)* ground_sand() { return &builtinSand; }

// "you say the fix to this stupid situation is to eliminate competing source of truth and i agree with that."
// 「[Fable 5.2] The node this sand names, alone, for ground code: it compiles none of the hooks, so」
// 「[Fable 5.2] it cannot read a Sand, and it read a file on disk for what the sand already says.」
import qntxblock : ParsedQntx, NODE_ABI;

extern (C) export const(ParsedQntx)* ground_sand_node() { return &builtinSand.parsed.qntx; }
extern (C) export ulong ground_sand_node_abi() { return NODE_ABI; }
