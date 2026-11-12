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

## Windows app only

| Component | License | Source |
|---|---|---|
| FFmpeg 7.1.2 (`libavcodec` H.264 decoder, `libswscale`; statically linked) | LGPL-2.1-or-later | https://ffmpeg.org |
| .NET runtime and WPF | MIT | https://github.com/dotnet |
| ONNX Runtime | MIT | https://github.com/microsoft/onnxruntime |
| Microsoft.ML.Tokenizers | MIT | https://github.com/dotnet/machinelearning |
| System.Security.Cryptography.ProtectedData | MIT | https://github.com/dotnet/runtime |
| Microsoft WebView2 SDK | BSD-3-Clause | https://www.nuget.org/packages/Microsoft.Web.WebView2 |
| SSH.NET (LG TV connection) | MIT | https://github.com/sshnet/SSH.NET |
| BouncyCastle.Cryptography (used by SSH.NET) | MIT | https://github.com/bcgit/bc-csharp |
| Microsoft.Extensions.Logging.Abstractions (used by SSH.NET) | MIT | https://github.com/dotnet/runtime |
| Microsoft Visual C++ 2015–2022 runtime (`vcruntime140*.dll`, `msvcp140*.dll`, `concrt140.dll`; needed by ONNX Runtime) | Microsoft Visual Studio license terms, "Distributable Code" (redist.txt) | https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files |

The Visual C++ runtime DLLs are Microsoft's redistributable files, copied unmodified from the Visual Studio
`VC\Redist\MSVC\…\x64\Microsoft.VC14x.CRT` folder and placed next to `CouchSubs.exe` (app-local deployment, as
Microsoft documents). They are system libraries in the sense of the GPL and are not covered by CouchSubs' AGPL license.

FFmpeg is built from the unmodified upstream release with the configuration in
`.github/workflows/windows.yml`. You can rebuild `couchsubs_native.dll` with your own FFmpeg build using
`windows/native/CMakeLists.txt` and place it next to `CouchSubs.exe`.

## Downloaded on first use (Windows)

| Component | License | Source |
|---|---|---|
| OPUS-MT English→Turkish translation model (`opus-mt-tc-big-en-tr`, ONNX export) | CC BY 4.0 | Language Technology Research Group, University of Helsinki — https://huggingface.co/Helsinki-NLP/opus-mt-tc-big-en-tr, ONNX conversion https://huggingface.co/onnx-community/opus-mt-tc-big-en-tr |

The model is used unmodified (int8 quantised ONNX files as published by onnx-community).

## Downloaded on first use of Turkish dubbing (Mac)

| Component | License | Source |
|---|---|---|
| Pocket TTS Turkish (model weights, tokenizer and six synthetic voices) | CC BY 4.0, by wite-tech, based on Kyutai's Pocket TTS (CC BY 4.0) | https://huggingface.co/wite-tech/pocket-tts-turkish |

The model and voices are used unmodified. CouchSubs shortens long pauses in the generated audio. The voices are
synthetic and are not recordings of real people.

## Mac app

Text recognition (Vision) and translation (Translation framework) are provided by macOS.

## Trademarks

CouchSubs is not affiliated with or endorsed by Sony Interactive Entertainment. "PlayStation" and "PS5"
are trademarks of Sony Interactive Entertainment Inc. LG and webOS are trademarks of LG Electronics Inc.
