# Third-Party Notices

KotodamaVoiceが利用または公開ソースに含める第三者成果物を以下に示します。
各成果物にはKotodamaVoice本体のMIT Licenseではなく、記載したライセンスが適用されます。

## whisper.cpp

- 用途: 音声認識Workerへ組み込む推論Runtime
- 取得元: https://github.com/ggml-org/whisper.cpp
- 固定revision: `371b5a7561823ab2bb32142d2751e35e7534727b`
- ライセンス: MIT License
- ライセンス全文: [Licenses/whisper.cpp-LICENSE.txt](Licenses/whisper.cpp-LICENSE.txt)

## llama.cpp

- 用途: 文字整形Workerへ組み込む推論Runtime
- 取得元: https://github.com/ggml-org/llama.cpp
- 固定revision: `bb4caa7540188872173c44d161602d9271386413`
- ライセンス: MIT License
- ライセンス全文: [Licenses/llama.cpp-LICENSE.txt](Licenses/llama.cpp-LICENSE.txt)

## OpenSpec skills

- 用途: `.agents/skills`に含まれる開発支援用生成物
- 取得元: https://github.com/Fission-AI/OpenSpec
- 固定版: `1.10.0`
- ライセンス: MIT License
- ライセンス全文: [Licenses/OpenSpec-LICENSE.txt](Licenses/OpenSpec-LICENSE.txt)

## OpenAI Whisper models

- 用途: 利用者が配布元から取得する音声認識モデル
- 取得元: https://huggingface.co/ggerganov/whisper.cpp
- 固定revision: `5359861c739e955e79d9a303bcbc70fb988958b1`
- 対象: `whisper-large-v3-turbo-f16`、`whisper-large-v3-turbo-q5-0`
- ライセンス: MIT License
- ライセンス全文: [Licenses/OpenAI-Whisper-LICENSE.txt](Licenses/OpenAI-Whisper-LICENSE.txt)

モデルファイルはアプリやDMGに同梱せず、利用者の操作後に上記取得元から直接取得します。

## Gemma 4 E4B IT QAT Q4_0 model

- 用途: 利用者が配布元から取得する文字整形モデル
- 取得元: https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf
- 固定revision: `4b4a2c1d584be7264f87aac328a1bc739ce81b6c`
- 対象: `gemma-4-e4b-it-qat-q4-0`
- ライセンス: Apache License 2.0
- ライセンス全文: [Licenses/Apache-2.0.txt](Licenses/Apache-2.0.txt)

モデルファイルはアプリやDMGに同梱せず、利用者の操作後に上記取得元から直接取得します。
