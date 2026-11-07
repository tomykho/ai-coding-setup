# CLI tools
- `rg` text search, `fd` file finding (both respect .gitignore).
- `ast-grep run -p '<pattern>' -l <lang>` for structural code search and multi-file rewrites (`-r`). Not `sg` (deprecated).
- `jq` JSON, `yq` YAML/TOML/XML, `jc <cmd>` to turn command output (ps, df, dig...) into JSON for jq.
- `difft` syntax-aware diffs, `shellcheck` before running non-trivial shell scripts.
- `hyperfine -N` for timing claims, `tokei` for codebase size/language overview, `ctags` for symbol locations.
- `gh` for GitHub data (`--json` + `--jq`), not scraping github.com.
- Prefix with `rtk` to shrink output: `rtk git`, `rtk gh`, `rtk rg`, `rtk ast-grep`, `rtk test <cmd>` (failures only),
  `rtk err <cmd>` (errors only), `rtk log`. Use the raw command when you need full exact output (diffs you'll edit from, exact lines).
- `rtk bulk-read --question "..." <paths>` to learn what docs say; read raw only to quote/edit lines. Never pass secrets (.env, keys).
