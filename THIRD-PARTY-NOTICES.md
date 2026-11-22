# Third-party notices / Üçüncü taraf bileşenler

CouchSubs is licensed under the GNU AGPL-3.0 (see [LICENSE](LICENSE)). It includes or downloads the
following third-party components. Full source code for CouchSubs, including the build scripts that
produce the bundled libraries, is available at https://github.com/yorulmazsinan/couchsubs.

## Bundled in the Mac and Windows apps

| Component | License | Source |
|---|---|---|
| chiaki-ng (`libchiaki`, Remote Play) | AGPL-3.0 with OpenSSL exception | https://github.com/chiaki-ng/chiaki-ng |
| nanopb | zlib | https://github.com/nanopb/nanopb |
| Jerasure | BSD-3-Clause | https://github.com/ceph/jerasure |
| GF-Complete | BSD-3-Clause | https://github.com/ceph/gf-complete |
| curl | curl license (MIT/X derivative) | https://curl.se |
| OpenSSL 3 | Apache-2.0 | https://www.openssl.org |
| json-c | MIT | https://github.com/json-c/json-c |
| libevent | BSD-3-Clause | https://libevent.org |
| miniupnpc | BSD-3-Clause | https://miniupnp.tuxfamily.org |
| TizenSdb.Core (Samsung TV connection and package signing) | MIT, Copyright (c) Patrick Stel | https://github.com/PatrickSt1991/tizen-sdb |
| Apps2Samsung (Samsung sign-in and certificate request flow, adapted) | MIT, Copyright (c) 2025 Patrick Stel | https://github.com/Jellyfin2Samsung/Samsung-Jellyfin-Installer |
| .NET runtime (Mac TV install helper, Native AOT) | MIT | https://github.com/dotnet/runtime |
| pocket-tts (Turkish dubbing voice engine, unmodified release binary; includes xn-ptts, Apache-2.0, and SentencePiece, Apache-2.0) | MIT, Copyright (c) Kyutai | https://github.com/kyutai-labs/pocket-tts |

The Android phone app (`couchsubs-android`, experimental "install the TV app from this phone") contains a Kotlin port of
the TizenSdb.Core sdb protocol and package signing and of the Apps2Samsung sign-in and certificate flow
(`app/src/main/java/com/couchsubs/mobile/tv/samsung/`), under the same MIT terms below. For installing on Android TV it
bundles Bouncy Castle (`bctls`, `bcpkix`, `bcprov`, `bcutil`; MIT, Copyright (c) The Legion of the Bouncy Castle Inc.,
https://www.bouncycastle.org) for the TLS 1.3 of ADB wireless debugging, and the released Android TV app
(`CouchSubs-androidtv.apk`, part of CouchSubs). For installing on LG TVs it bundles JSch (mwiede/jsch fork; BSD-3-Clause,
Copyright (c) 2002-2018 ymnk, JCraft, Inc., https://github.com/mwiede/jsch) for the developer-mode SSH connection, and the
released LG TV app (`com.couchsubs.tv_*_all.ipk`, part of CouchSubs).

The iPhone app (`couchsubs-ios`, "install the TV app from this phone") contains a Swift port of the same TizenSdb.Core and
Apps2Samsung code (`CouchSubs/TVInstall/`), under the same MIT terms below. It uses only Apple's frameworks (Security,
CryptoKit, CommonCrypto, Network) for TLS and signing. For LG TVs it contains its own minimal SSH client
(`CouchSubs/TVInstall/SshClient.swift`, part of CouchSubs under AGPL-3.0; written from RFC 4253/4252/4254, no third-party
SSH code), negotiating the same algorithms JSch uses with LG TVs. It bundles the released Android TV and LG TV apps and the Samsung CA
certificates below.

Samsung developer CA certificates (`vd_tizen_dev_author_ca`, `author_ca`, `vd_tizen_dev_public2`, `public2`) are
redistributed unmodified from Tizen Studio, solely so that the TV app can be signed for the user's own Samsung TV. They
are the property of Samsung Electronics Co., Ltd. and are not covered by the CouchSubs license.

MIT License text (TizenSdb.Core, Apps2Samsung): Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Game translation packs

The packs in `core/Sources/CouchSubsCore/Resources/packs` contain only hashed keys and Turkish text; no game text is
included. The Elden Ring pack (`elden-ring.json.gz`) was translated with Claude (Claude ile çevrildi) from the
English text dumps of the [Carian Archive](https://github.com/AsteriskAmpersand/Carian-Archive) (base game) and
[Impaler's Archive](https://github.com/ividyon/Impalers-Archive) (Shadow of the Erdtree). Its terminology follows the
glossary of the Elden Ring Turkish fan translation by mehmetkrn
([elden-ring-turkce-yama](https://github.com/mehmetkrn/elden-ring-turkce-yama), MIT License, Copyright (c) mehmetkrn).
ELDEN RING is a trademark of FromSoftware, Inc. and BANDAI NAMCO Entertainment Inc.

The Marvel's Spider-Man 2 pack (`marvels-spider-man-2.json.gz`) was translated with Claude (Claude ile çevrildi) from
the English [Marvel's Spider-Man 2 script](https://marvels-spider-man.fandom.com/wiki/Marvel%27s_Spider-Man_2_script)
and [menu transcript](https://marvels-spider-man.fandom.com/wiki/Marvel%27s_Spider-Man_2_menu_transcript) on the
Marvel's Spider-Man Wiki (Fandom, text under [CC BY-SA](https://creativecommons.org/licenses/by-sa/3.0/), by its
contributors), and from English lines CouchSubs users read on screen (shared subtitle pool). Marvel's Spider-Man 2 is
a trademark of Marvel and Sony Interactive Entertainment LLC.

## Windows app only

The Turkish command glossary in `UiCommands.cs` and the controller-icon detection in
`ButtonIcons.MarkFree` were adapted on 2026-11-20 from [GameTranslator's UiPrompts](https://gitlab.com/sefflex/GameTranslator/-/blob/2492049b8435962b05933075978dd52084c67bfc/windows/src/GameTranslator.Core/UiPrompts.cs)
and [IconWords](https://gitlab.com/sefflex/GameTranslator/-/blob/2492049b8435962b05933075978dd52084c67bfc/windows/src/GameTranslator.Core/IconWords.cs), by emir-kaya (Sefflex).
IconWords credits [Nino Game Translator's VisionReader](https://github.com/yunusdemirbag/nino-game-translator/blob/83c138fbf87292c800082270e4b33e771bae3df1/core/Sources/CouchSubsCore/Pipeline/VisionReader.swift)
for the `withIcons` and `withEdgeIcons` rules by Yunus Demirbağ. Both projects are based on
CouchSubs, Copyright (C) 2026 Sinan Yorulmaz. These adaptations are licensed under AGPL-3.0-only (see [LICENSE](LICENSE)).

| Component | License | Source |
|---|---|---|
| FFmpeg 7.1.2 (`libavcodec` H.264 decoder, `libswscale`; statically linked) | LGPL-2.1-or-later | https://ffmpeg.org |
| .NET runtime and WPF | MIT | https://github.com/dotnet |
| Html Agility Pack (reads GitHub release notes as text and links) | MIT, ZZZ Projects | https://github.com/zzzprojects/html-agility-pack |
| CTranslate2 4.9.0 (Windows CPU and NVIDIA CUDA inference) | MIT | https://github.com/OpenNMT/CTranslate2 |
| Python 3.12 embedded runtime | Python Software Foundation License | https://www.python.org/downloads/release/python-31210/ |
| NumPy (CTranslate2 wheel dependency) | BSD-3-Clause | https://github.com/numpy/numpy |
| PyYAML (CTranslate2 wheel dependency) | MIT | https://github.com/yaml/pyyaml |
| Microsoft.ML.Tokenizers | MIT | https://github.com/dotnet/machinelearning |
| System.Security.Cryptography.ProtectedData | MIT | https://github.com/dotnet/runtime |
| Microsoft WebView2 SDK | BSD-3-Clause | https://www.nuget.org/packages/Microsoft.Web.WebView2 |
| Greenlight protocol reference | MIT | https://github.com/unknownskl/greenlight |
| Node.js 22.14.0 runtime (Xbox helper) | MIT and bundled third-party licenses | https://github.com/nodejs/node |
| xal-node (Xbox Microsoft device-code authentication) | MIT | https://github.com/unknownskl/xal-node |
| xbox-webapi (home console discovery) | MIT | https://github.com/unknownskl/xbox-webapi |
| xbox-xcloud-player (WebRTC video reception) | MIT | https://github.com/unknownskl/xbox-xcloud-player |
| ip-address (ICE/Teredo address handling) | MIT | https://github.com/beaugunderson/ip-address |
| jose (Xbox token handling, bundled dependency) | MIT | https://github.com/panva/jose |
| uuid (bundled dependency) | MIT | https://github.com/uuidjs/uuid |
| uuid4 (bundled dependency) | ISC | https://www.npmjs.com/package/uuid4 |
| events (bundled browser EventEmitter) | MIT | https://github.com/browserify/events |
| SSH.NET (LG TV connection) | MIT | https://github.com/sshnet/SSH.NET |
| BouncyCastle.Cryptography (used by SSH.NET) | MIT | https://github.com/bcgit/bc-csharp |
| Microsoft.Extensions.Logging.Abstractions (used by SSH.NET) | MIT | https://github.com/dotnet/runtime |
| QRCoder 1.6.0 (QR code of the "Show on another device" address) | MIT | https://github.com/codebude/QRCoder |
| ONNX Runtime 1.24.4 (`onnxruntime.dll`, `Microsoft.ML.OnnxRuntime.DirectML`; advanced text recognition) | MIT | https://github.com/microsoft/onnxruntime |
| DirectML 1.15.4 (`DirectML.dll`, from the `Microsoft.AI.DirectML` package; GPU for advanced text recognition) | Microsoft Software License Terms (Microsoft DirectX Machine Learning) | https://www.nuget.org/packages/Microsoft.AI.DirectML/1.15.4 |
| Microsoft Visual C++ 2015–2022 runtime (`vcruntime140*.dll`, `msvcp140*.dll`, `concrt140.dll`; needed by CTranslate2) | Microsoft Visual Studio license terms, "Distributable Code" (redist.txt) | https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files |

The full copyright and license notices for Greenlight, the Xbox helper's bundled libraries, and the bundled Node.js
runtime are in `windows/xbox-bridge/licenses/` in the source tree and `xbox-bridge/licenses/` in the Windows package.
The Xbox helper adapts Greenlight's home-streaming protocol sequence; the full Greenlight application is not bundled.

The Visual C++ runtime DLLs are Microsoft's redistributable files, copied unmodified from the Visual Studio
`VC\Redist\MSVC\…\x64\Microsoft.VC14x.CRT` folder and placed next to `CouchSubs.exe` (app-local deployment, as
Microsoft documents). They are system libraries in the sense of the GPL and are not covered by CouchSubs' AGPL license.

`DirectML.dll` is Microsoft's redistributable file from the `Microsoft.AI.DirectML` NuGet package, distributed
unmodified next to `CouchSubs.exe`. Its license terms (in the package as `LICENSE.txt`) allow redistribution only in
applications for Windows and Xbox; it is not covered by CouchSubs' AGPL license.

FFmpeg is built from the unmodified upstream release with the configuration in
`.github/workflows/windows.yml`. You can rebuild `couchsubs_native.dll` with your own FFmpeg build using
`windows/native/CMakeLists.txt` and place it next to `CouchSubs.exe`.

## Downloaded on first use (Windows)

| Component | License | Source |
|---|---|---|
| OPUS-MT English→Turkish translation model (`opus-mt-tc-big-en-tr`, CTranslate2 conversion) | CC BY 4.0 | Language Technology Research Group, University of Helsinki — https://huggingface.co/Helsinki-NLP/opus-mt-tc-big-en-tr, conversion https://huggingface.co/Unbakedcookie/live-translator-models |
| PP-OCRv6 small text detection and recognition models (advanced text recognition, Windows option only) | Apache-2.0, Baidu / PaddlePaddle | https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx, https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx (pinned revision) |
| NVIDIA CUDA 12.8 cuBLAS and runtime (Windows GPU option only) | NVIDIA CUDA Toolkit license; downloaded license at `cuda-12.8/CUDA-LICENSE.txt` | https://developer.download.nvidia.com/compute/cuda/redist/ |

The model is downloaded as a SHA-256-verified CTranslate2 float16 conversion from the pinned source above. CouchSubs uses int8 computation on CPU and float16 on a compatible NVIDIA CUDA GPU.

The PP-OCRv6 models are downloaded unmodified from the pinned revisions above and verified with SHA-256 before use.

## Downloaded on first use of Turkish dubbing (Mac)

| Component | License | Source |
|---|---|---|
| Pocket TTS Turkish (model weights, tokenizer and six synthetic voices) | CC BY 4.0, by wite-tech, based on Kyutai's Pocket TTS (CC BY 4.0) | https://huggingface.co/wite-tech/pocket-tts-turkish |

The model and voices are used unmodified. CouchSubs shortens long pauses in the generated audio. The voices are
synthetic and are not recordings of real people.

## Mac app

Text recognition (Vision) and translation (Translation framework) are provided by macOS.

## Android app

| Component | License | Source |
|---|---|---|
| ZXing core 3.5.3 (`com.google.zxing:core`; QR code of the "Show on another device" address) | Apache-2.0 | https://github.com/zxing/zxing |

The Mac and iPhone apps draw the same QR code with the system's Core Image (`CIQRCodeGenerator`).

## Phone apps: Xbox home streaming (Beta)

| Component | License | Source |
|---|---|---|
| WebRTC for Android (`io.github.webrtc-sdk:android`, Google libwebrtc build) | BSD-3-Clause with WebRTC patent grant | https://github.com/webrtc-sdk/webrtc |
| WebRTC for iOS and macOS (`stasel/WebRTC`, Google libwebrtc build) | BSD-3-Clause with WebRTC patent grant | https://github.com/stasel/WebRTC |
| Protocol constants and sequence from xal-node, xbox-webapi, xbox-xcloud-player and Greenlight (ported to Kotlin and Swift) | MIT | https://github.com/unknownskl |

The Android, iPhone and Mac apps do not bundle the Node.js helper or the JavaScript player. They send the same requests
as the Windows helper and open WebRTC with the platform library; H.264 is decoded by the device's hardware decoder. The MIT
notices for the ported projects are in `windows/xbox-bridge/licenses/`.

## Trademarks

CouchSubs is not affiliated with or endorsed by Sony Interactive Entertainment. "PlayStation" and "PS5"
are trademarks of Sony Interactive Entertainment Inc. LG and webOS are trademarks of LG Electronics Inc.
