# Changelog

All notable changes to SshAutoLogin.jl are recorded in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-09-23

### Changed

- `scripts/run.jl`, `sandbox/run.jl`, and `test/runtests.jl` activate their environment through the `activate.jl` of that environment, so the test suite runs as `julia test/runtests.jl` without `--project`.
- The README opens with a short file tree, the environment setup, the entry points, and the component status; the full tree moved into a collapsed section.
- Dependabot runs weekly and also watches the formatting environment.
- The `log_level` comment of `config.example.toml` lists every accepted value, including `DEBUG1` to `DEBUG3`.

### Fixed

- `Pkg.test()` passes. The sandbox scenario that spawns `scripts/run.jl` inherited the load path that `Pkg.test` exports, which lacks the standard libraries, so the child could not load `Pkg` and the scenario failed; the spawned driver now starts without `JULIA_LOAD_PATH` and `JULIA_PROJECT`. Running the suite as a script was not affected.
- `julia format/format.jl --check` fails when a source file does not parse. JuliaFormatter skips such a file with a warning and still reports success, so a syntax error in a file that no test loads passed the formatting job; the script now lists the files that do not parse and exits 1 before formatting, in both modes.

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
