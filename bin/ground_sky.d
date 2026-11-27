module ground_sky;

// "like, even sky, you would think it doesnt have to be the same binary."
import sky : handleSky;

extern (C) int main(int argc, const(char)** argv) {
    import standing : standWhereStarted;
    standWhereStarted("ground_sky", argv);
    return handleSky(argc, argv);
}
