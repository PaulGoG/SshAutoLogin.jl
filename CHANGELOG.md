# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** the exported names are the four configuration types, `MissingBinaryError`, `load_config`, `parse_config`, `plan_sessions`, and `launch_sessions`; the validators, the wrapper-script generator, the command builders, and the runtime-directory helpers are internal. `SshAutoLogin.main` is public but not exported.
- **Breaking:** `XDG_RUNTIME_DIR` is required. The launcher used to fall back to a temporary directory on the regular file system, where unconsumed wrappers, which hold passwords, were never purged; it now refuses to run without the runtime directory of a systemd user session.
- **Breaking:** `load_config` refuses a configuration file readable by group or others, naming its mode; create the file with `install -m 600 config.example.toml config.toml`.
- **Breaking:** titles must not contain `;` or `%`: Konsole splits `-p` profile properties on `;` and expands `%` sequences in tab titles. Only `;;` was refused before.
- **Breaking:** IPv6 literals are accepted without square brackets only; `ssh` does not strip them from `user@host`, so a bracketed literal could never connect.
- Each launch writes its files into a fresh directory below `$XDG_RUNTIME_DIR/ssh-autologin/`, so two launches within one settle window no longer overwrite each other's wrappers. The directory is removed after the wait, and also when every emulator process has exited without executing every wrapper; it is kept only when the wait times out while an emulator is still running, and a later launch removes it once it is older than the settle timeout.
- Konsole is started detached from the launcher's session with its standard streams closed, so an interrupt of the launcher no longer closes every session, and Konsole's diagnostics no longer land in the launcher's terminal. Both modes use `--separate`.
- `ssh` runs with `PubkeyAuthentication=no` and `PreferredAuthentications=keyboard-interactive,password`, so an agent holding many keys cannot exhaust the server's authentication attempts and an encrypted key cannot raise a passphrase prompt that `sshpass` does not answer.
- The settle wait uses a monotonic clock, and `bash` is checked for in `PATH` with the other prerequisites.
- The configuration path may be given once; a second path, or `--config` followed by an option, is a usage error.
- The parser takes its defaults from the default instances of `GlobalConfig` and `TerminalOptions`, so a default is written in one place.
- `julia format/format.jl` refuses any argument other than `--check`.
- `.gitignore` ignores every `.toml` file except the tracked environment files and the template; the test environment carries `[compat]` bounds, Dependabot watches it, the formatter bound is `~2.14.0`, and CI also runs `Pkg.test()` on the stable Julia job.

## [0.2.1] - 2026-09-23

### Changed

- `scripts/run.jl`, `sandbox/run.jl`, and `test/runtests.jl` activate their environment through the `activate.jl` of that environment, so the test suite runs as `julia test/runtests.jl` without `--project`.
- README reordered: short file tree first, full tree in a collapsed section.
- Dependabot runs weekly and also watches the formatting environment.
- The `log_level` comment of `config.example.toml` lists every accepted value, including `DEBUG1` to `DEBUG3`.

### Fixed

- `Pkg.test()` failed in the sandbox scenario that spawns `scripts/run.jl`: the child inherited the load path exported by `Pkg.test`, which lacks the standard libraries. The child now starts without `JULIA_LOAD_PATH` and `JULIA_PROJECT`.
- `format/format.jl` lists the files that do not parse and exits 1, in both modes. JuliaFormatter skips such files and reports success, so a syntax error in a file no test loads used to pass CI.

## [0.2.0] - 2026-09-10

### Fixed

- Booleans are rejected for the numeric keys `port`, `connect_timeout`, and `launch_settle_timeout`; previously `port = true` was accepted as port 1.

### Changed

- `emulator` and `log_level` must match the documented spelling exactly; the emulator name is also the executable looked up in `PATH`, so a differently cased value could pass validation and then fail at launch.
- The sandbox asserts the content of the driver output, not only the exit status.
- The command-line driver moved from `scripts/run.jl` into the package as `SshAutoLogin.main(args; io, err)`, which returns the exit status instead of calling `exit` and takes its output streams as arguments; the script is a thin wrapper. The sandbox and the test suite call the driver in process, so the suite no longer spawns one Julia process per scenario.
- The test environment consumes the package through a relative `[sources]` entry, which Julia 1.11 and later read directly; `test/activate.jl` still develops the package on Julia 1.10.
- The README no longer suggests `Pkg.add(url=...)`; the package is meant to be run from the clone.

## [0.1.0] - 2026-09-08

### Added

- TOML configuration with schema validation: typed keys, rejection of unknown keys, RFC 1123 host names or IP literals, POSIX-style account names, titles free of Konsole's `;;` delimiter.
- `tabs` mode (one Konsole window, one tab per target, via `--tabs-from-file`) and `windows` mode (one window per target).
- Self-removing wrapper scripts in `$XDG_RUNTIME_DIR` that hand the password to `sshpass` over a file descriptor, so that no credential appears in an environment, an argument vector, a log, or `--dry-run` output.
- `hold` option implemented in the wrapper script, applying to every tab.
- Bounded wait for the emulator to consume the wrapper scripts (`launch_settle_timeout`), with a warning and retained files when it does not.
- Command-line entry point `scripts/run.jl` with `--config` and `--dry-run`.
- Test suite with Aqua, JET, ExplicitImports, and launch tests against a stub emulator; formatting enforced by a dedicated `format/` environment and CI job.

[Unreleased]: https://github.com/PaulGoG/SshAutoLogin.jl/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/PaulGoG/SshAutoLogin.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/PaulGoG/SshAutoLogin.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/PaulGoG/SshAutoLogin.jl/releases/tag/v0.1.0
