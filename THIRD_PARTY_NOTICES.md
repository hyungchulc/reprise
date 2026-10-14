# Third-Party Notices

Reprise uses the following open-source components. Their unmodified license and
notice files are included in `Resources/Licenses` and in the packaged app.

| Component | Version | Upstream |
| --- | --- | --- |
| MCP Swift SDK | 0.12.1 | https://github.com/modelcontextprotocol/swift-sdk |
| EventSource | 1.5.1 | https://github.com/mattt/EventSource |
| Swift System | 1.8.1 | https://github.com/apple/swift-system |
| Swift Log | 1.16.1 | https://github.com/apple/swift-log |
| Sparkle | 2.10.0 | https://github.com/sparkle-project/Sparkle |
| swift-sqlcipher (SQLCipher 4.12.0, SQLite 3.51.1, LibTomCrypt) | 1.13.0 | https://github.com/skiptools/swift-sqlcipher |
| Argmax OSS (WhisperKit, SpeakerKit; includes code from Hugging Face swift-transformers, Apache 2.0) | 1.1.1 | https://github.com/argmaxinc/argmax-oss-swift |

Swift NIO, Swift Collections, Swift Atomics and Swift Argument Parser also appear in the resolved package
graph for SDK and command-line tooling. Their licenses are retained for completeness. SQLite is in the
public domain and LibTomCrypt is released under the Unlicense; SQLCipher's BSD license
and the package's MIT license are included. Apple frameworks are supplied by macOS. No Rewind binaries, assets, recordings,
model weights or proprietary SDKs are distributed with Reprise.

Speech models are not bundled. When a person chooses them, Reprise downloads OpenAI's Whisper
models converted by Argmax (MIT, https://huggingface.co/argmaxinc/whisperkit-coreml) and the
pyannote speaker models converted by Argmax (CC BY 4.0, https://huggingface.co/argmaxinc/speakerkit-coreml)
from Hugging Face.
