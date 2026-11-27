module ground_hook;

// "ground_hook as the hooks binary"
import hookrun : hookMain;

extern (C) int main(int argc, const(char)** argv) {
    import standing : standWhereStarted;
    standWhereStarted("ground_hook", argv);
    return hookMain(argc, argv);
}
