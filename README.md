# SshAutoLogin.jl

[![CI](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/CI.yml)

Opens one KDE Konsole tab, or one window, per remote host listed in a TOML file and logs in with password authentication, so that a set of compute nodes is reachable with a single command.

```
SshAutoLogin/
├── .github/
│   ├── dependabot.yml         # Monthly updates of the GitHub Actions pins
│   └── workflows/
│       └── CI.yml             # Test suite on Julia LTS, stable, and pre-release
├── .gitignore                 # Credentials, manifests, editor artifacts
├── .JuliaFormatter.toml       # Formatting rules (YAS style)
├── CHANGELOG.md               # Release history
├── LICENSE                    # MIT
├── Project.toml               # Package metadata and compat bounds
├── README.md
├── SECURITY.md                # Threat model and vulnerability reporting
├── activate.jl                # Activates and instantiates the root environment
├── config.example.toml        # Configuration template
├── format/
│   ├── Project.toml           # Formatting environment (JuliaFormatter 2.14+)
│   ├── activate.jl            # Activates the formatting environment
│   └── format.jl              # Formats the repository; --check verifies without writing
├── scripts/
│   └── run.jl                 # Command-line entry point
├── src/
│   ├── SshAutoLogin.jl        # Module and exports
│   ├── validation.jl          # Field constraints and patterns
│   ├── types.jl               # SshTarget, GlobalConfig, TerminalOptions, SessionConfig
│   ├── config.jl              # TOML parsing with schema checks
│   └── process.jl             # Wrapper scripts, emulator commands, launch logic
└── test/
    ├── Project.toml           # Test environment (Aqua, JET, ExplicitImports)
    ├── activate.jl            # Activates the test environment against the local source
    └── runtests.jl
```

## Requirements

Linux with a systemd user session. Fedora with KDE Plasma is the development platform; any distribution that ships Konsole works. The launcher needs Konsole, the OpenSSH client, and `sshpass` 1.06 or newer:

```bash
sudo dnf install konsole openssh-clients sshpass
```

Julia 1.10 or newer.

## Installation

Clone the repository and use it in place; this is the intended way to run the command-line entry point:

```bash
git clone https://github.com/PaulGoG/SshAutoLogin.jl.git
cd SshAutoLogin.jl
julia activate.jl          # root environment
julia test/activate.jl     # test environment, developed against the local source
julia format/activate.jl   # formatting environment
```

The package is not registered. To use the library API from another environment, add it by URL:

```bash
julia -e 'using Pkg; Pkg.add(url="https://github.com/PaulGoG/SshAutoLogin.jl")'
```

## Usage

Copy the template and fill in the targets. `config.toml` is ignored by git.

```bash
cp config.example.toml config.toml
```

| Task | Command |
|---|---|
| Open all sessions | `julia scripts/run.jl` |
| Use another configuration file | `julia scripts/run.jl --config path/to/config.toml` |
| Print the emulator commands without launching | `julia scripts/run.jl --dry-run` |
| Run the test suite | `julia --project=test test/runtests.jl` |
| Format the sources | `julia format/format.jl` |
| Check formatting without writing | `julia format/format.jl --check` |

The script activates its own environment, so `--project` is not needed.

From Julia:

```julia
using SshAutoLogin
config = load_config("config.toml")
plan_sessions(config)      # emulator commands, no side effects
launch_sessions(config)    # opens the sessions and returns the emulator processes
```

## Configuration

```toml
[globals]
connect_timeout = 10                     # integer > 0; units: s
strict_host_key_checking = "accept-new"  # one of: "accept-new" | "yes" | "no"
log_level = "ERROR"                      # OpenSSH LogLevel

[terminal]
emulator = "konsole"                     # one of: "konsole"
mode = "tabs"                            # one of: "tabs" | "windows"
hold = false                             # keep the tab open after the session ends
launch_settle_timeout = 30               # number > 0; units: s

[[targets]]
host = "192.168.1.100"                   # host name, IPv4 address, or IPv6 literal
port = 22                                # integer in [1, 65535]
user = "admin"
password = "example_password_1"
title = "Cluster Node 01"                # optional; default: user@host:port
strict_host_key_checking = "accept-new"  # optional per-target override
```

The parser rejects unknown keys, wrong value types, and values outside the documented constraints, naming the offending key. Host names must satisfy RFC 1123 (IPv4 and IPv6 literals are accepted as well), account names must be a letter or underscore followed by letters, digits, `.`, `_`, or `-`, passwords must be non-empty and free of control characters, and titles must not contain the sequence `;;`, which delimits fields in Konsole's tab list.

## How a session is opened

For every target the launcher writes a short Bash script into `$XDG_RUNTIME_DIR/ssh-autologin/`, a user-private directory (mode 0700) on an in-memory file system. The script removes itself as its first action, hands the password to `sshpass` through a pipe on file descriptor 3, and replaces itself with `sshpass -d 3 ssh ...`. In `tabs` mode Konsole is started once with `--tabs-from-file` pointing at a list with one script per tab; in `windows` mode Konsole is started once per target. The launcher then waits, at most `launch_settle_timeout` seconds, until every script has removed itself, deletes the tab list, and returns. If the emulator exits early or the wait times out, a warning reports the remaining files; they are purged at the next launch.

With `hold = true` the script does not replace itself: it waits for the SSH session to end, prints the exit status, and waits for Enter before the tab closes. Because this is implemented in the script rather than with Konsole's `--hold`, it applies to every tab.

## Security model

The password is read from `config.toml` into memory and written into the wrapper script, which lives on tmpfs with mode 0700 and unlinks itself when executed; under normal operation it exists for a fraction of a second. `sshpass -d` reads the password from a pipe, so it never appears in a process environment or an argument vector (`ps`, `/proc/*/cmdline`, `/proc/*/environ`). Nothing the package prints, logs, or returns from `show` contains a password, including `--dry-run` output.

The threat model is a single-user workstation. A process running under the same account can read the wrapper during its short lifetime, and the package does not defend against a compromised account or a hostile administrator. Host-key verification follows the configured policy: `accept-new` (default) trusts a host on first contact and refuses a changed key, `yes` requires the key to be known already, and `no` disables verification. If `XDG_RUNTIME_DIR` is unset the scripts are written to a temporary directory on the regular file system and a warning is printed.

Vulnerability reports: see [SECURITY.md](SECURITY.md).

## Limitations

Linux only, and Konsole is the only supported emulator. Authentication is by password only; hosts that accept keys are better served by `ssh` with an agent, and key-based targets are a planned addition.

## License

MIT, see [LICENSE](LICENSE).
