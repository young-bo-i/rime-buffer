# rime-easy-en source notice

- Upstream: https://github.com/BlindingDark/rime-easy-en
- Source revision: `54a4a07289412efc54134092c0d945f895a71ed3`
- Imported asset: `easy_en.dict.yaml`
- License: GNU Lesser General Public License v3.0; see `rime-easy-en-LICENSE`.

The upstream Lua/wordninja enhancement is intentionally not bundled. Enter输入法
uses the dictionary through its own `english.schema.yaml` and existing
`lua/en_spacer.lua` filter.
