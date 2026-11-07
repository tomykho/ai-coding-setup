# CLI tools
- `rg` text search, `fd` file finding (both respect .gitignore).
- `ast-grep run -p '<pattern>' -l <lang>` for structural code search and multi-file rewrites (`-r`). Not `sg` (deprecated).
- `jq` JSON, `yq` YAML/TOML/XML, `jc <cmd>` to turn command output (ps, df, dig...) into JSON for jq.
- `difft` syntax-aware diffs, `shellcheck` before running non-trivial shell scripts.
- `hyperfine -N` for timing claims, `tokei` for codebase size/language overview, `ctags` for symbol locations.
- `gh` for GitHub data (`--json` + `--jq`), not scraping github.com.

# Blocked by a hook (use the alternative the first time)
- Edit files with the Edit/Write tools, never `sed -i`, `perl -pi`, `> file`, or `tee file`. Writing under /tmp is fine.
- No `grep -r` or `find` without `-maxdepth`: use `rg` / `fd`. Single-file `grep` and `cmd | grep` are fine.
- No unbounded listings: not `ls -R` or bare `tree`; use `fd -d 2`, `tree -L 2`, or `tokei`. Bound `git log` (`--oneline -n 20`).
- No inline Python for JSON: use `jq`/`yq`. For other scripts, Write a file and run `python3 <file>`.
- No `curl` to GitHub: use `gh api`.
