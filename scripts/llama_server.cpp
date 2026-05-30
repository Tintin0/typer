#include "llama.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <functional>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static std::string json_get_string(const std::string &s, const std::string &key) {
    std::string pat = "\"" + key + "\"";
    size_t p = s.find(pat);
    if (p == std::string::npos) return "";
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) return "";
    p = s.find('"', p);
    if (p == std::string::npos) return "";
    std::string out;
    bool esc = false;
    for (size_t i = p + 1; i < s.size(); ++i) {
        char c = s[i];
        if (esc) {
            switch (c) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                default: out += c; break;
            }
            esc = false;
        } else if (c == '\\') {
            esc = true;
        } else if (c == '"') {
            break;
        } else {
            out += c;
        }
    }
    return out;
}

static int json_get_int(const std::string &s, const std::string &key, int def) {
    std::string pat = "\"" + key + "\"";
    size_t p = s.find(pat);
    if (p == std::string::npos) return def;
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) return def;
    ++p;
    while (p < s.size() && std::isspace((unsigned char)s[p])) ++p;
    char *end = nullptr;
    long v = std::strtol(s.c_str() + p, &end, 10);
    return end == s.c_str() + p ? def : (int)v;
}

static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    return out;
}

static std::string trim(std::string s) {
    while (!s.empty() && std::isspace((unsigned char)s.front())) s.erase(s.begin());
    while (!s.empty() && std::isspace((unsigned char)s.back())) s.pop_back();
    return s;
}

static bool contains_special_fragment(const std::string &s) {
    return s.find("<|") != std::string::npos || s.find("|>") != std::string::npos || s.find("<turn") != std::string::npos;
}

static std::string lower_ascii(std::string s) {
    for (char &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

static bool looks_bad_completion(const std::string &s) {
    std::string t = lower_ascii(trim(s));
    if (t.empty()) return true;
    if (contains_special_fragment(t)) return true;
    if (t == "cont" || t == "continuation" || t == "text:" || t.rfind("continuation:", 0) == 0 || t.rfind("text:", 0) == 0) return true;
    if (t.find("as an ai") != std::string::npos || t.find("i'm sorry") != std::string::npos) return true;
    if (t.size() > 2) {
        size_t p = t.find(' ');
        if (p != std::string::npos) {
            std::string w = t.substr(0, p);
            int repeats = 0;
            size_t off = 0;
            while (off < t.size()) {
                if (t.compare(off, w.size(), w) == 0) repeats++;
                size_t next = t.find(' ', off);
                if (next == std::string::npos) break;
                off = next + 1;
            }
            if (repeats >= 4) return true;
        }
    }
    return false;
}

static std::string limit_words(const std::string &s, int max_words) {
    std::string out;
    int words = 0;
    bool in_word = false;
    for (char c : s) {
        out += c;
        if (std::isspace((unsigned char)c)) {
            if (in_word) {
                words++;
                if (words >= max_words) break;
            }
            in_word = false;
        } else {
            in_word = true;
        }
    }
    if (in_word) words++;
    return trim(out);
}

static std::string first_line_clean(std::string s) {
    auto cut_marker = [&](const std::string &m) {
        size_t p = s.find(m);
        while (p != std::string::npos) { s.erase(p, m.size()); p = s.find(m); }
    };
    cut_marker("<|channel>thought<channel|>");
    cut_marker("<|channel>final<channel|>");
    cut_marker("<|channel>");
    cut_marker("<channel|>");
    cut_marker("<|think|>");
    cut_marker("<turn|>");
    cut_marker("<|turn>model");
    cut_marker("<|turn>user");
    return trim(s);
}

static std::string remove_echo(std::string out, const std::string &context) {
    out = trim(out);
    for (const std::string &label : {"Continuation:", "Next words:", "Insert:", "Completion:"}) {
        size_t lp = out.rfind(label);
        if (lp != std::string::npos) out = trim(out.substr(lp + label.size()));
    }
    std::string ctx = trim(context);
    if (ctx.empty()) return out;
    size_t p = out.find(ctx);
    if (p != std::string::npos) {
        return trim(out.substr(p + ctx.size()));
    }
    for (size_t n = std::min<size_t>(ctx.size(), 120); n > 12; --n) {
        std::string suffix = ctx.substr(ctx.size() - n);
        p = out.find(suffix);
        if (p != std::string::npos) return trim(out.substr(p + suffix.size()));
    }
    return out;
}

class LlamaEngine {
public:
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    int n_ctx = 1024;
    int pos = 0;
    std::vector<llama_token> last_prompt_tokens;
    std::vector<llama_logit_bias> special_biases;

    explicit LlamaEngine(const std::string &path) {
        llama_backend_init();
        llama_log_set([](enum ggml_log_level, const char *, void *) {}, nullptr);

        auto mp = llama_model_default_params();
        mp.n_gpu_layers = 999;
        mp.use_mmap = true;
        mp.use_mlock = false;
        model = llama_model_load_from_file(path.c_str(), mp);
        if (!model) throw std::runtime_error("failed to load model: " + path);

        auto cp = llama_context_default_params();
        cp.n_ctx = n_ctx;
        cp.n_batch = 512;
        cp.n_ubatch = 512;
        cp.n_threads = std::max(2u, std::thread::hardware_concurrency() / 2);
        cp.n_threads_batch = std::max(2u, std::thread::hardware_concurrency() / 2);
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        cp.swa_full = false;
        cp.no_perf = true;
        ctx = llama_init_from_model(model, cp);
        if (!ctx) throw std::runtime_error("failed to create llama context");
        vocab = llama_model_get_vocab(model);
        init_biases();
    }

    ~LlamaEngine() {
        if (ctx) llama_free(ctx);
        if (model) llama_model_free(model);
        llama_backend_free();
    }

    std::vector<llama_token> tokenize(const std::string &text, bool add_special) {
        int n = llama_tokenize(vocab, text.c_str(), (int)text.size(), nullptr, 0, add_special, true);
        if (n < 0) n = -n;
        std::vector<llama_token> toks(n);
        int got = llama_tokenize(vocab, text.c_str(), (int)text.size(), toks.data(), (int)toks.size(), add_special, true);
        if (got < 0) throw std::runtime_error("tokenize failed");
        toks.resize(got);
        return toks;
    }

    std::string detok(llama_token tok) {
        char buf[256];
        int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
        if (n < 0) return "";
        return std::string(buf, buf + n);
    }

    void init_biases() {
        std::vector<std::string> specials = {"<|", "|>", "<|think|>", "<|turn>", "<turn|>", "<|channel>", "<channel|>", "<bos>", "<eos>"};
        std::vector<llama_token> ids;
        for (const auto &s : specials) {
            auto toks = tokenize(s, false);
            ids.insert(ids.end(), toks.begin(), toks.end());
        }
        std::sort(ids.begin(), ids.end());
        ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
        for (auto id : ids) special_biases.push_back({id, -INFINITY});
    }

    llama_sampler * make_sampler(const std::vector<llama_token> &prompt_tokens) {
        auto params = llama_sampler_chain_default_params();
        params.no_perf = true;
        llama_sampler * chain = llama_sampler_chain_init(params);
        if (!special_biases.empty()) {
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), (int32_t)special_biases.size(), special_biases.data()));
        }
        // Inline autocomplete wants the high-probability continuation, not a
        // creative tangent. Keep a mild repetition penalty, then a low
        // temperature with tight top-k/top-p so suggestions track what the user
        // most likely meant to type.
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, 1.08f, 0.0f, 0.0f));
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20));
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.90f, 1));
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.20f));
        llama_sampler_chain_add(chain, llama_sampler_init_dist(0xC07A));
        for (auto tok : prompt_tokens) llama_sampler_accept(chain, tok);
        return chain;
    }

    void decode_tokens(const std::vector<llama_token> &tokens, int token_start, int token_end, int pos_start, bool logits_last) {
        const int chunk = 512;
        for (int off = token_start; off < token_end; off += chunk) {
            int n = std::min(chunk, token_end - off);
            std::vector<llama_pos> positions(n);
            std::vector<int32_t> n_seq_id(n, 1);
            std::vector<llama_seq_id> seq_values(n, 0);
            std::vector<llama_seq_id *> seq_ptrs(n);
            std::vector<int8_t> logits(n, 0);
            for (int i = 0; i < n; ++i) {
                positions[i] = pos_start + (off - token_start) + i;
                seq_ptrs[i] = &seq_values[i];
            }
            if (logits_last && off + n == token_end) logits[n - 1] = 1;
            llama_batch batch{};
            batch.n_tokens = n;
            batch.token = const_cast<llama_token *>(tokens.data() + off);
            batch.embd = nullptr;
            batch.pos = positions.data();
            batch.n_seq_id = n_seq_id.data();
            batch.seq_id = seq_ptrs.data();
            batch.logits = logits.data();
            if (llama_decode(ctx, batch) != 0) throw std::runtime_error("llama_decode failed");
        }
    }

    void prepare_prompt(const std::vector<llama_token> &toks) {
        int common = 0;
        int max_common = std::min(last_prompt_tokens.size(), toks.size());
        while (common < max_common && last_prompt_tokens[common] == toks[common]) common++;

        // Re-decode the last prompt token so logits always correspond to this prompt,
        // while keeping as much reusable KV prefix as possible.
        if (!last_prompt_tokens.empty() && common > 0 && !toks.empty()) common = std::min<int>(common, (int)toks.size() - 1);

        if (common <= 0) {
            llama_memory_clear(llama_get_memory(ctx), true);
            pos = 0;
        } else {
            llama_memory_seq_rm(llama_get_memory(ctx), 0, common, -1);
            pos = common;
        }
        if (pos < (int)toks.size()) {
            decode_tokens(toks, pos, (int)toks.size(), pos, true);
            pos = (int)toks.size();
        }
        last_prompt_tokens = toks;
    }

    // on_token(full_output_so_far) is called after each token; returning false stops
    // generation early (used for streaming + early mid-word suppression).
    std::string generate(const std::string &prompt, int max_tokens,
                         const std::function<bool(const std::string &)> &on_token = nullptr) {
        auto toks = tokenize(prompt, false);
        if ((int)toks.size() + max_tokens + 8 > n_ctx) {
            toks.erase(toks.begin(), toks.begin() + ((int)toks.size() + max_tokens + 8 - n_ctx));
        }
        prepare_prompt(toks);

        llama_sampler *smpl = make_sampler(toks);
        std::string out;
        for (int i = 0; i < max_tokens; ++i) {
            llama_token id = llama_sampler_sample(smpl, ctx, -1);
            llama_sampler_accept(smpl, id);
            if (llama_vocab_is_eog(vocab, id)) break;
            out += detok(id);
            std::vector<llama_token> one = { id };
            decode_tokens(one, 0, 1, pos, true);
            pos++;
            if (on_token && !on_token(out)) break;
        }
        llama_sampler_free(smpl);
        return out;
    }
};

static std::string prompt_complete(const std::string &context, int max_words) {
    // Gemma is trained with a leading <bos>. Without it the base model emits
    // degenerate, repetitive garbage ("the the The", "your help with your help
    // with your"). tokenize() runs with parse_special=true, so the literal
    // "<bos>" string is mapped to the real BOS token id. This single token is
    // the difference between incoherent and coherent continuations.
    return "<bos>" + context;
}

static std::string prompt_typo(const std::string &context, const std::string &word) {
    return "<bos><|turn>user\nCorrect this last word if misspelled. Output only correction or OK. Context: " + context + "\nLast word: " + word + "<turn|>\n<|turn>model\n<|channel>final\n";
}

static std::string last_word(const std::string &s) {
    int i = (int)s.size() - 1;
    while (i >= 0 && !std::isalnum((unsigned char)s[i]) && s[i] != '\'') i--;
    int end = i + 1;
    while (i >= 0 && (std::isalnum((unsigned char)s[i]) || s[i] == '\'')) i--;
    return end > i + 1 ? s.substr(i + 1, end - i - 1) : "";
}

int main(int argc, char **argv) {
    std::string model_path;
    bool check = false;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if ((a == "--model" || a == "--model-path") && i + 1 < argc) model_path = argv[++i];
        else if (a == "--check") check = true;
    }
    if (model_path.empty()) {
        const char *home = std::getenv("HOME");
        model_path = std::string(home ? home : ".") + "/Library/Application Support/typer/Models/gemma-4-E2B-i1-Q4_K_M.gguf";
    }

    try {
        LlamaEngine engine(model_path);
        if (check) {
            const char *tmpl = llama_model_chat_template(engine.model, nullptr);
            std::cerr << "chat_template=" << (tmpl ? tmpl : "(null)") << std::endl;
            auto t0 = std::chrono::steady_clock::now();
            std::string out = first_line_clean(engine.generate(prompt_complete("I was walking to the store when I realized", 7), 14));
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
            std::cerr << "loaded; sample=" << out << " latency_ms=" << ms << std::endl;
            return 0;
        }

        std::string line;
        while (std::getline(std::cin, line)) {
            try {
                std::string task = json_get_string(line, "task");
                std::string context = json_get_string(line, "context");
                int max_words = json_get_int(line, "max_words", 7);
                if (context.size() > 1600) context = context.substr(context.size() - 1600);

                if (task == "typo") {
                    std::string word = last_word(context);
                    std::string out = limit_words(first_line_clean(engine.generate(prompt_typo(context, word), 8)), 2);
                    if (out.empty() || out == "OK" || out == word) {
                        std::cout << "{\"ok\":true,\"suggestion\":null}\n" << std::flush;
                    } else {
                        std::cout << "{\"ok\":true,\"suggestion\":{\"kind\":\"typo\",\"original\":\"" << json_escape(word) << "\",\"replacement\":\"" << json_escape(out) << "\"}}\n" << std::flush;
                    }
                } else {
                    int max_tokens = std::max(8, std::min(18, max_words + 7));
                    bool ctx_ends_space = context.empty() || std::isspace((unsigned char)context.back());
                    bool ctx_ends_alnum = !context.empty() && std::isalnum((unsigned char)context.back());

                    // The model signals a word boundary itself: a leading-space token
                    // ("jumps" -> " jumps") means "new word"; no leading space ("etion"
                    // after "autocompl", "!") means "continue this word / punctuation".
                    bool first_seen = false, lead_space = false, suppressed = false;
                    std::string last_emitted;

                    auto shape = [&](const std::string &full) -> std::string {
                        std::string s = first_line_clean(full);
                        s = remove_echo(s, context);
                        size_t nl = s.find('\n'); if (nl != std::string::npos) s.resize(nl);
                        s = limit_words(s, max_words);
                        if (!s.empty() && !ctx_ends_space && lead_space) s = " " + s;
                        return s;
                    };

                    // Stream partial completions token-by-token so the UI shows the
                    // first word almost immediately instead of waiting for all of them.
                    std::string raw = engine.generate(prompt_complete(context, max_words), max_tokens,
                        [&](const std::string &full) -> bool {
                            std::string s = first_line_clean(full);
                            if (s.empty()) return true;
                            if (!first_seen) {
                                first_seen = true;
                                lead_space = std::isspace((unsigned char)full[0]) != 0;
                                // Early mid-word suppression: stop before flashing a
                                // wrong subword continuation.
                                if (ctx_ends_alnum && !lead_space && std::isalnum((unsigned char)s[0])) {
                                    suppressed = true; return false;
                                }
                            }
                            std::string shaped = shape(full);
                            if (!shaped.empty() && shaped != last_emitted) {
                                last_emitted = shaped;
                                std::cout << "{\"p\":\"" << json_escape(shaped) << "\"}\n" << std::flush;
                            }
                            int wc = 0; bool inw = false;
                            for (char c : shaped) { if (std::isspace((unsigned char)c)) { if (inw) wc++; inw = false; } else inw = true; }
                            if (inw) wc++;
                            // Stop at enough words, or at a natural sentence end.
                            char last = shaped.empty() ? 0 : shaped.back();
                            if (wc >= 3 && (last == '.' || last == '!' || last == '?')) return false;
                            return wc < max_words;
                        });

                    std::string out;
                    if (!suppressed) {
                        out = shape(raw);
                        if (looks_bad_completion(out)) out.clear();
                    }
                    if (out.empty()) {
                        std::cout << "{\"ok\":true,\"suggestion\":null}\n" << std::flush;
                    } else {
                        std::cout << "{\"ok\":true,\"suggestion\":{\"kind\":\"completion\",\"text\":\"" << json_escape(out) << "\"}}\n" << std::flush;
                    }
                }
            } catch (const std::exception &e) {
                std::cout << "{\"ok\":false,\"error\":\"" << json_escape(e.what()) << "\",\"suggestion\":null}\n" << std::flush;
            }
        }
    } catch (const std::exception &e) {
        std::cerr << "fatal: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
