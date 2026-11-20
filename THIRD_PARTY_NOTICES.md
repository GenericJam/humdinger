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
| Erlang/OTP runtime and Elixir standard library | the app's `otp.zip` and native libraries | Apache-2.0 |
| OpenSSL 3 (linked into OTP's `crypto`) | native library | Apache-2.0 |
| SQLite (through `exqlite`) | native library | Public domain |
| Mob framework and plugins (`mob`, `mob_midi`, `mob_background`, `mob_print`, `mob_camera`, `mob_scanner`, `mob_bluetooth`, `mob_secure_store`), including the Android bridge code generated into `android/` | BEAMs, native libraries, Kotlin | MIT, each with its own copyright notice |
| Elixir dependencies (`ecto`, `ecto_sql`, `ecto_sqlite3`, `exqlite`, `db_connection`, `decimal`, `jason`, `telemetry`, `nimble_parsec`) | BEAMs | MIT or Apache-2.0, as each package states (`mix.lock` pins the versions) |
| AndroidX, Jetpack Compose, CameraX, Media3, AndroidX Security, Coil | Java/Kotlin libraries | Apache-2.0 |
| Google ML Kit barcode scanning (`com.google.mlkit:barcode-scanning`, used to scan FMutate's pairing QR code) | Java library and model | [ML Kit Terms of Service](https://developers.google.com/ml-kit/terms), not an open-source licence |
| `android/gradlew` | build script (not in the APK) | Apache-2.0, copyright 2015 the original authors |

These components keep their own licences and copyright notices; Humdinger's MIT grant does not relicense them.
Generated or copied framework code is not newly owned by Humdinger because it sits in this repository or the APK.
