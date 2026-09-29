# GUS local model notice

## Model and source

ISyCode Móvil can optionally download one model directly to the user's device:

- **Model:** Qwen1.5-1.8B-Chat, GGUF Q4_K_M
- **File:** `qwen1_5-1_8b-chat-q4_k_m.gguf`
- **Repository:** [Qwen/Qwen1.5-1.8B-Chat-GGUF](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF)
- **Pinned revision:** [`07800fcba6d5d1df3dfa36e3763374a2c0d9f91b`](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/tree/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b)
- **Uploader listed for this GGUF revision:** JustinLin610
- **Size:** 1,217,752,928 bytes
- **SHA-256:** `702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18`
- **License:** [Tongyi Qianwen Research License Agreement](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/blob/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/LICENSE), non-commercial terms. A copy is included at [docs/licenses/TONGYI_QIANWEN_RESEARCH_LICENSE.txt](licenses/TONGYI_QIANWEN_RESEARCH_LICENSE.txt).

The model weights are not part of this repository, app bundle, IPA, or CI
artifact. The app downloads only this pinned file after the user taps the
download button, checks the exact byte count and SHA-256, and stores it under
`Files > On My iPhone > ISyCode Móvil > ISyCode/GUS/Models`. On launch, the app
looks for the pinned file and verifies it again before making it available. A
model already stored by an earlier version is moved to this folder only after
the same size and SHA-256 checks. A different model cannot be selected or
imported through this feature.

## Required attribution

The model license requires this notice in copies of the model materials:

> Tongyi Qianwen is licensed under the Tongyi Qianwen RESEARCH LICENSE AGREEMENT, Copyright (c) Alibaba Cloud. All Rights Reserved.

ISyCode Móvil and GUS are not authored, endorsed, or supported by Alibaba Cloud
or Qwen. The GGUF uploader attribution above identifies the uploader shown by
the pinned repository revision; it does not claim that uploader authored the
Qwen model.

## Scope and safeguards

- ISyCode is an open-source, non-commercial project. The chosen model's license
  is also non-commercial; users must follow the license for their own use.
- Prompts and inference are local when **GUS local** is selected. The explicit
  model download contacts the pinned Hugging Face route.
- GUS local currently provides guidance only. Tool calls remain disabled until
  Qwen 1.5's tool-call format has been characterized and validated. A local
  model, role prompt, or downloaded model does not grant file permissions.
- The native capability catalog and iOS permissions remain unchanged. Any
  future file mutation must pass the app's visible approval flow.
- Neither this project nor its future independent models use Qwen outputs to
  train, fine-tune, distill, or create training data for another LLM.

## Inference runtime

The iOS runtime is built from [llama.cpp](https://github.com/ggml-org/llama.cpp)
commit `842b1880415d6f508f03b789e5ce70194def7bfd`. It is linked as a native
XCFramework under its MIT license (copy: [docs/licenses/LLAMA_CPP_MIT_LICENSE.txt](licenses/LLAMA_CPP_MIT_LICENSE.txt)); the app does not launch a CLI or subprocess.
