# Licensing scope and third-party notices

## Humdinger-owned code: MIT

The root [LICENSE](LICENSE) grants the MIT License for original Humdinger code and assets, copyright (c) 2026
GenericJam: the Elixir app, `c_src/`, scripts, the icon and Mimi artwork, docs and design boards (fonts the
boards load keep their own licences), except the material listed below or carrying its own notice. It does not
replace any upstream copyright, attribution or licence.

## Bundled in the Android APK under other terms

| Material | Where | Terms |
|---|---|---|
| Inter, JetBrains Mono, Bricolage Grotesque (Latin static instances) and Noto Music fonts | `priv/fonts/`, copied to `android/app/src/main/res/font/` | SIL Open Font License 1.1; copyright notices and licence text in [priv/fonts/OFL.txt](priv/fonts/OFL.txt), which ships with the fonts (in the app's `priv/`) |
| Piano preview samples, from the University of Iowa Musical Instrument Samples by Lawrence Fritts | `priv/piano/` | Free to use without restrictions per the publisher; provenance, processing and attribution in [priv/piano/LICENSE](priv/piano/LICENSE), which ships with the samples |
| Erlang/OTP runtime and Elixir standard library | the app's `otp.zip` and native libraries | Apache-2.0, with bundled third-party parts under their own licences as OTP's licence documentation lists (e.g. PCRE2, BSD-3-Clause, and asmjit, zlib, linked into the native library; jQuery files in `common_test`, MIT) |
| OpenSSL 3 (OTP's `crypto`, also linked into the app's native library) | native libraries | Apache-2.0 |
| SQLite (through `exqlite`) | native library | Public domain |
| Mob framework, tooling and plugins (`mob`, `mob_dev`, `mob_midi`, `mob_background`, `mob_print`, `mob_camera`, `mob_scanner`, `mob_bluetooth`, `mob_secure_store`, `mob_audio_io`), including the Android bridge code generated into `android/` and the Mob logos (from `mob_dev`) in `android/app/src/main/assets/` | BEAMs, native libraries, Kotlin, images | MIT, per each package's metadata; `mob` and `mob_audio_io` (Hex packages) and `mob_secure_store` (a git dependency pinned in `mix.lock`) include their LICENSE files |
| Elixir dependencies (`ecto`, `ecto_sql`, `ecto_sqlite3`, `exqlite`, `db_connection`, `decimal`, `jason`, `telemetry`, `nimble_parsec`) | BEAMs | MIT or Apache-2.0, as each package states (`mix.lock` pins the versions) |
| AndroidX, Jetpack Compose, CameraX, Media3, AndroidX Security, Coil, and their transitive Maven dependencies (Kotlin standard library, kotlinx.coroutines, Guava, Gson, OkHttp, Okio, Tink, Firebase components and encoders, Google datatransport) | Java/Kotlin libraries | Apache-2.0, except the two rows below |
| Protocol Buffers, shaded inside Tink (pulled in by AndroidX Security) | Java library | BSD-3-Clause, copyright 2008 Google Inc. ([licence](https://github.com/protocolbuffers/protobuf/blob/main/LICENSE)) |
| Mozilla Public Suffix List (`okhttp3/internal/publicsuffix/publicsuffixes.gz`, shipped by OkHttp with its NOTICE) | data file | MPL-2.0, unmodified; source at [publicsuffix.org](https://publicsuffix.org/) |
| Roboto Medium (`res/RV.ttf`, added by a library dependency) | font | Apache-2.0, copyright 2011 Google Inc. |
| Google ML Kit barcode scanning (`com.google.mlkit:barcode-scanning`, used to scan FMutate's pairing QR code): its Java library, native `libbarhopper_v3.so` and `assets/mlkit_barcode_models/` | Java library, native library, models | [ML Kit Terms of Service](https://developers.google.com/ml-kit/terms), not an open-source licence |
| Google libraries pulled in by ML Kit under the Android SDK licence (`play-services-base`, `play-services-basement`, `play-services-tasks`, `com.google.android.odml:image`) | Java libraries | [Android Software Development Kit License](https://developer.android.com/studio/terms), not an open-source licence |
| `android/gradlew` | build script (not in the APK) | Apache-2.0, copyright 2015 the original authors |

These components keep their own licences and copyright notices; Humdinger's MIT grant does not relicense them.
Generated or copied framework code is not newly owned by Humdinger because it sits in this repository or the APK.
