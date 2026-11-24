---
license: gemma
tags:
- gemma3
- gemma
- google
- llama-cpp
- gguf-my-repo
pipeline_tag: text-generation
library_name: transformers
extra_gated_heading: Access Gemma on Hugging Face
extra_gated_prompt: To access Gemma on Hugging Face, you’re required to review and
  agree to Google’s usage license. To do this, please ensure you’re logged in to Hugging
  Face and click below. Requests are processed immediately.
extra_gated_button_content: Acknowledge license
base_model: google/gemma-3-270m
---

# hugginllam/gemma-3-270m-Q4_K_M-GGUF
This model was converted to GGUF format from [`google/gemma-3-270m`](https://huggingface.co/google/gemma-3-270m) using llama.cpp via the ggml.ai's [GGUF-my-repo](https://huggingface.co/spaces/ggml-org/gguf-my-repo) space.
Refer to the [original model card](https://huggingface.co/google/gemma-3-270m) for more details on the model.

## Use with llama.cpp
Install llama.cpp through brew (works on Mac and Linux)

```bash
brew install llama.cpp

```
Invoke the llama.cpp server or the CLI.

### CLI:
```bash
llama-cli --hf-repo hugginllam/gemma-3-270m-Q4_K_M-GGUF --hf-file gemma-3-270m-q4_k_m.gguf -p "The meaning to life and the universe is"
```

### Server:
```bash
llama-server --hf-repo hugginllam/gemma-3-270m-Q4_K_M-GGUF --hf-file gemma-3-270m-q4_k_m.gguf -c 2048
```

Note: You can also use this checkpoint directly through the [usage steps](https://github.com/ggerganov/llama.cpp?tab=readme-ov-file#usage) listed in the Llama.cpp repo as well.

Step 1: Clone llama.cpp from GitHub.
```
git clone https://github.com/ggerganov/llama.cpp
```

Step 2: Move into the llama.cpp folder and build it with `LLAMA_CURL=1` flag along with other hardware-specific flags (for ex: LLAMA_CUDA=1 for Nvidia GPUs on Linux).
```
cd llama.cpp && LLAMA_CURL=1 make
```

Step 3: Run inference through the main binary.
```
./llama-cli --hf-repo hugginllam/gemma-3-270m-Q4_K_M-GGUF --hf-file gemma-3-270m-q4_k_m.gguf -p "The meaning to life and the universe is"
```
or 
```
./llama-server --hf-repo hugginllam/gemma-3-270m-Q4_K_M-GGUF --hf-file gemma-3-270m-q4_k_m.gguf -c 2048
```
