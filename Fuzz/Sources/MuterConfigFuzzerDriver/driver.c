// libFuzzer supplies main() and calls the Swift-exported
// LLVMFuzzerTestOneInput function. Keeping a C source file makes this a Clang
// executable target, avoiding SwiftPM's synthesized Swift main entry point.
extern int LLVMFuzzerTestOneInput(const unsigned char *data, unsigned long size);

void mutantkit_fuzzer_link_anchor(void) {
    (void)LLVMFuzzerTestOneInput;
}
