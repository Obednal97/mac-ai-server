# Models

The local AI model is the part that runs on your Mac instead of on Anthropic's servers. The installer picks one based on two things:
- **how much memory** your Mac has;
- **which chip** it has.

## The short version

- **Bigger memory means a bigger, smarter model.**
- **The installer downloads only the recommended model.** At the end it offers a second, faster "quick helper" model.
- **`mac-ai-server models`** shows every model that fits your Mac, marked `[recommended]`, `[downloaded]` and `[in use]`.
- **`mac-ai-server models default <name>`** switches. It downloads the model first if needed.
- **Local models are far less capable than Claude's own.** Use `claude` for important work, and `claude-local` for private, offline or unlimited tasks. Check what local models tell you.

## What 8-bit and 4-bit mean

A model is billions of numbers.
- **8-bit** stores each one in 8 bits. That's very close to the original quality.
- **4-bit** squeezes them into 4 bits, so the model is about half the size and needs half the memory. It's a little less accurate, and you notice it most on long, tricky tasks.

The installer uses 8-bit when it fits comfortably, and 4-bit when memory is tighter.

Two more terms you'll see:
- **27B, 35B, 122B:** billions of numbers. More usually means smarter and slower.
- **"35B-A3B":** a "mixture of experts" model. Only about 3 billion of its numbers work on each word, so it's several times faster. It does think at length before answering, so a full answer isn't always quicker.

## Model formats: M5 vs M3/M4

Ollama 0.19 and later run models on Apple's own MLX engine. Tags ending in `mxfp8` (8-bit) or `nvfp4` (4-bit) are MLX models.

- **M5 and newer:** get the MLX tags. They're the fastest there.
- **M3 and M4:** get the equivalent **GGUF** tags, `q8_0` (8-bit) or `q4_K_M` (4-bit). MLX tags read long prompts much more slowly on those chips, and coding agents send long prompts.
- **M1 and M2:** warned, not blocked (untested); they get the M3 choices.

## The tier table

Your Mac's memory is rounded down to the nearest row. A 40 GB Mac uses the 36 GB row, but its GPU limit follows the real 40 GB.

**Recommended (primary) model:**

| Memory | M5 and newer | M3 / M4 |
|---|---|---|
| 16 GB | `bonsai-2:27b` (8.3 GB) | `bonsai-2:27b` (8.3 GB) |
| 24 GB | `bonsai-2:27b` (8.3 GB) | `bonsai-2:27b` (8.3 GB) |
| 32 GB | `qwen3.8:27b-nvfp4` (18.2 GB) | `qwen3.8:27b-q4_K_M` (17.7 GB) |
| 36 GB | `qwen3.8:27b-nvfp4` (18.2 GB) | `qwen3.8:27b-q4_K_M` (17.7 GB) |
| 48 GB | `qwen3.8:27b-mxfp8` (31.7 GB) | `qwen3.8:27b-q8_0` (30 GB) |
| 64 GB | `qwen3.8:27b-mxfp8` (31.7 GB) | `qwen3.8:27b-q8_0` (30 GB) |
| 96 GB | `qwen3.8:27b-mxfp8` (31.7 GB) | `qwen3.8:27b-q8_0` (30 GB) |
| 128 GB | `qwen3.8:27b-mxfp8` (31.7 GB) | `qwen3.8:27b-q8_0` (30 GB) |

**Quick helper (fast) model, context and GPU limit:**

| Memory | Fast, M5 and newer | Fast, M3 / M4 | Context | GPU limit |
|---|---|---|---|---|
| 16 GB | `qwen3.5:9b-nvfp4` (7.2 GB) | `qwen3.5:9b-q4_K_M` (6.6 GB) | 32K | 12 GB |
| 24 GB | `qwen3.5:9b-mxfp8` (11.2 GB) | `qwen3.5:9b-q8_0` (10.4 GB) | 64K | 18 GB |
| 32 GB | `gemma4:26b-nvfp4` (16.1 GB) | `qwen3.5:9b-q8_0` (10.4 GB) | 64K | 24 GB |
| 36 GB | `qwen3.6:35b-a3b-nvfp4` (23.6 GB) | `qwen3.6:35b-a3b-q4_K_M` (23.9 GB) | 64K | 28 GB |
| 48 GB | `qwen3.6:35b-a3b-nvfp4` (23.6 GB) | `qwen3.6:35b-a3b-q4_K_M` (23.9 GB) | 64K | 40 GB |
| 64 GB | `qwen3.6:35b-a3b-mxfp8` (38 GB) | `qwen3.6:35b-a3b-q8_0` (38.7 GB) | 128K | 56 GB |
| 96 GB | `qwen3.6:35b-a3b-mxfp8` (38 GB) | `qwen3.6:35b-a3b-q8_0` (38.7 GB) | 128K | 86 GB |
| 128 GB | `qwen3.6:35b-a3b-mxfp8` (38 GB) | `qwen3.6:35b-a3b-q8_0` (38.7 GB) | 128K | 116 GB |

The columns explained:
- **Context** is how much text the model can keep in mind at once: the conversation, the files it read, and the tool results. Ollama and `claude-local` are both set to the same value, so Claude Code summarises the conversation before the model would lose track.
- **GPU limit** is the memory the model may use. It's your memory minus a reserve for macOS: 4 GB at 16, 6 at 24, 8 at 32 to 64, 10 at 96 and 12 at 128. The installer computes it for your Mac and re-applies it at every startup.

**Opt-in upgrade (96 and 128 GB, M5 and newer only):** `ornith-1.5:122b-nvfp4` (73.4 GB). It scores higher than Qwen 3.8, but it's brand new and untested here, so it's offered, not chosen.

### Honest notes per tier

These come from `config/models.json`. Speeds are words (tokens) per second while answering, and they depend a lot on the chip (base, Pro, Max) and the task.

- **16 GB:** entry level. Good for questions, explanations and small edits at roughly 8 to 15 words per second. It's not for big autonomous refactors. Bonsai 2 is a new, compact version of Qwen 3.8 and has had little testing. Keep other apps closed, because memory is tight.
- **24 GB:** a compromise tier for everyday coding help and small multi-file changes, at roughly 8 to 18 words per second (faster on Pro chips). If Bonsai struggles on long agent runs, switch to the 9B model, which is steadier but less capable.
- **32 GB:** the first tier with a full-size 27B coding model. Good quality for real projects, but a basic (non-Pro) chip gives only about 8 to 17 words per second. The fast model trades some accuracy for speed.
- **36 GB:** a strong 27B model with room for long sessions. Roughly 10 to 17 words per second on Pro chips, and up to about 60 on Max chips. The fast model is about 4 times quicker but thinks a lot, so answers can take as long.
- **48 GB:** the best accuracy per GB for coding agents. Roughly 10 to 40 words per second depending on the chip; Qwen 3.8 measured about 21 tokens/s on an M5 Pro. The fast model reached about 86 on an M5 Pro.
- **64 GB:** the same top-accuracy 27B model with room for very long sessions. The fast model is 8-bit and much quicker, with some loss of depth.
- **96 / 128 GB:** the proven 27B model with lots of spare memory. Roughly 20 to 90 words per second; these are estimates, not measurements. Ornith 1.5 122B is the opt-in upgrade.

### What has been tested

- **Tested:** only the **48 GB row on an M5 Pro** (Mac mini, macOS 27). Qwen 3.8 27B 8-bit passed 4 of 4 checkable tasks at about 21 tokens/s (measured 20.6). It used about 6 times fewer thinking words and was 3 to 6 times faster per task than Qwen 3.6 27B.
- **Untested:** every other row, and every M3 and M4 choice. The picks follow published benchmarks and memory arithmetic. If you run one, please share `mac-ai-server doctor --report` and how it felt.
- **Model tags:** every tag in the table is checked against the Ollama library automatically (`tests/check-model-tags.sh`).

## Switching models

```bash
mac-ai-server models                          # what fits, what's downloaded, what's in use
mac-ai-server models default qwen3.6:27b-mxfp8  # download if needed, then switch claude-local and chat
mac-ai-server models add-fast                 # the quick helper for your tier
mac-ai-server models remove <name>            # free the disk space (not the model in use)
```

`models default` saves your choice as `MAS_MODEL` in `~/.mac-ai-server/config.env` and asks for your admin password.

To try another model once, without switching:

```bash
chat qwen3.6:35b-a3b-nvfp4
CLAUDE_LOCAL_MODEL=qwen3.6:35b-a3b-nvfp4 claude-local
```

Only one large model fits in the GPU limit at a time. Ollama swaps them on demand, and the first answer after a swap takes a few seconds longer.

**Updates never switch your model by themselves.** If a newer version of this repo recommends a different model, `mac-ai-server update` prints:

```
Recommended model changed: <old> → <new>. Run: mac-ai-server models default <new>
```

You decide.

## Why speeds vary

Ollama's MLX engine uses **speculative decoding**: it drafts a few words ahead and checks them in one go. On the reference Mac it accepted 1 to 3 drafted words per step. That's why Qwen 3.8 27B 8-bit (32 GB) runs at about 21 tokens/s on an M5 Pro, when plain arithmetic (memory speed divided by model size) predicts 8 to 10. Predictable text such as code and repeated phrases speeds up the most, so this guide gives ranges, not single numbers.
