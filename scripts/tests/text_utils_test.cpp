// Unit tests for the pure text helpers in scripts/llama_server.cpp.
//
// Defines TYPER_TEXT_TEST and #includes the server source, which compiles ONLY the pure
// string functions (llama.cpp, the LlamaEngine class, and main() are #ifndef-guarded out).
// No model, no llama, no network — fast and deterministic. Build/run via scripts/run_tests.sh.
#define TYPER_TEXT_TEST
#include <cstdio>
#include <string>
#include "../llama_server.cpp"

static int g_fail = 0, g_pass = 0;

#define EXPECT_EQ(actual, expected)                                                       \
    do {                                                                                   \
        std::string _a = (actual), _e = (expected);                                        \
        if (_a == _e) { g_pass++; }                                                        \
        else { g_fail++; std::printf("  FAIL %s:%d  %s\n    got:  \"%s\"\n    want: \"%s\"\n", \
                                     __FILE__, __LINE__, #actual, _a.c_str(), _e.c_str()); } \
    } while (0)

#define EXPECT_TRUE(cond)                                                                  \
    do { if (cond) { g_pass++; } else { g_fail++;                                           \
        std::printf("  FAIL %s:%d  expected true: %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main() {
    std::printf("== trim_midword_overlap (the mid-word doubling bug) ==\n");
    EXPECT_EQ(trim_midword_overlap("stance.", "assis"), "tance.");        // "assis"+"stance" -> "tance"
    EXPECT_EQ(trim_midword_overlap("eting.", "mee"), "ting.");            // "mee"+"eting"  -> "ting"
    EXPECT_EQ(trim_midword_overlap("assistance", "assis"), "tance");      // model re-emitted the whole word
    EXPECT_EQ(trim_midword_overlap("richt.", "Nachr"), "icht.");          // "Nachr"+"richt" -> "icht"
    EXPECT_EQ(trim_midword_overlap("che.", "Wo"), "che.");                // no overlap -> unchanged ("Woche")
    EXPECT_EQ(trim_midword_overlap("that", "docu"), "that");             // wrong word, no overlap (dict-gate drops)
    EXPECT_EQ(trim_midword_overlap(" and", "assis"), " and");            // leading space => new word, unchanged
    EXPECT_EQ(trim_midword_overlap("", "assis"), "");                    // empty completion
    EXPECT_EQ(trim_midword_overlap("stance", ""), "stance");             // empty partial

    std::printf("== bridge_to_suffix (mid-line collision) ==\n");
    EXPECT_EQ(bridge_to_suffix(" report you requested.", " for your review."), " report you requested");
    EXPECT_EQ(bridge_to_suffix(" I have some questions.", " before we proceed."), " I have some questions");
    // completion that just restates the suffix -> stripped to empty (suppressed)
    EXPECT_EQ(bridge_to_suffix(" and let me know your comments.", " and let me know your comments."), "");
    EXPECT_EQ(bridge_to_suffix("", " for review."), "");

    std::printf("== stable_tail ==\n");
    EXPECT_EQ(stable_tail("short string", 100), "short string");         // shorter than cap -> unchanged
    EXPECT_TRUE(stable_tail("Hello there. This is the tail of it.", 15).size() <= 15);
    EXPECT_TRUE(std::string("Hello there. This is the tail of it.").find(stable_tail("Hello there. This is the tail of it.", 15)) != std::string::npos);

    std::printf("== limit_words ==\n");
    EXPECT_EQ(limit_words("one two three four", 2), "one two");
    EXPECT_EQ(limit_words("hello", 5), "hello");

    std::printf("== looks_bad_completion ==\n");
    EXPECT_TRUE(looks_bad_completion("as an AI language model"));
    EXPECT_TRUE(looks_bad_completion("Continuation:"));
    EXPECT_TRUE(looks_bad_completion("<|endoftext|>"));
    EXPECT_TRUE(!looks_bad_completion("the quarterly report"));

    std::printf("== is_orphan_number ==\n");
    EXPECT_TRUE(is_orphan_number("100%", "the zoom is "));               // leading percentage (UI chrome)
    EXPECT_TRUE(is_orphan_number("42", "the answer is "));               // bare number
    EXPECT_TRUE(!is_orphan_number(" apples", "I have 5"));               // context mid-number, real word
    EXPECT_TRUE(!is_orphan_number("0 percent off", "save "));            // number followed by words

    std::printf("== first_line_clean (strips markers/tags; does NOT cut newlines) ==\n");
    EXPECT_EQ(first_line_clean("  <|turn>model  the answer "), "the answer");
    EXPECT_EQ(first_line_clean("text <em>bold</em> here"), "text bold here");
    EXPECT_EQ(first_line_clean("hello\nworld"), "hello\nworld");   // newline cut happens later in shape()

    std::printf("== remove_echo (only overlaps > 12 chars, or a full-context / label match) ==\n");
    EXPECT_EQ(remove_echo("I was walking to the store then home", "I was walking to the store"), "then home");
    EXPECT_EQ(remove_echo("Continuation: and then we left", "we sat down"), "and then we left");

    std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
