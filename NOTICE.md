# 📜 Attribution

SuperDictate is derived from
[Parakey](https://github.com/rcourtman/parakey), originally created by
Richard Courtman and distributed under the MIT License.

The original copyright notice and license are preserved in `LICENSE`.
SuperDictate includes substantial product, interface, service-management,
history, statistics, and dictation-workflow modifications by the SuperDictate
contributors.

Speech recognition (NVIDIA Parakeet TDT 0.6B v3, GGUF q8_0) is performed
locally through [parakeet.cpp](https://github.com/mudler/parakeet.cpp)
(pinned commit `e747acdaee69b916cef62263ae5f718bda9ff3f3`), which is
statically vendored into `swift/Sources/parakeet_cpp/upstream/` by
`scripts/vendor-parakeet-cpp.sh` and distributed under the MIT License.
parakeet.cpp itself vendors [ggml](https://github.com/ggml-org/ggml)
(pinned submodule `e705c5fed490514458bdd2eaddc43bd098fcce9b`, tag
`v0.13.0`), also MIT-licensed. Exact upstream license texts, captured at
the pinned commits, are checked in at
`swift/Sources/parakeet_cpp/upstream/LICENSE-parakeet-cpp.txt` and
`swift/Sources/parakeet_cpp/upstream/LICENSE-ggml.txt`. Third-party Swift
package licenses remain available through their respective upstream
projects.

