# SshAutoLogin.jl

[![CI](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![JET](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)
[![Code Style: YAS](https://img.shields.io/badge/code%20style-yas-violet.svg)](https://github.com/jrevels/YASGuide)
[![Format](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/Format.yml/badge.svg?branch=main)](https://github.com/PaulGoG/SshAutoLogin.jl/actions/workflows/Format.yml?query=branch%3Amain)
[![Julia](https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2FPaulGoG%2FSshAutoLogin.jl%2Fmain%2FProject.toml&query=%24.compat.julia&label=julia&logo=julia&color=9558b2)](https://julialang.org/downloads/)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?logo=linux)](#environment-setup)

Opens one KDE Konsole tab, or one window, per remote host listed in a TOML file and logs in to each, with a password from the file or with the keys and host aliases of `~/.ssh/config`.

```
SshAutoLogin.jl/
├── src/                   # Package: configuration parser, wrapper scripts, launcher, CLI driver
├── scripts/run.jl         # Command-line entry point
├── test/                  # Test suite and its environment
├── format/                # Formatting environment and script
├── config.example.toml    # Configuration template
├── activate.jl            # Activates and instantiates the root environment
├── Project.toml
├── CHANGELOG.md
└── SECURITY.md
```

The complete tree is under [Repository layout](#repository-layout).

## Environment setup

Linux with a systemd user session: the launcher writes its scripts under `XDG_RUNTIME_DIR` and refuses to run without it. I develop and test on Fedora with KDE Plasma, and any distribution that ships Konsole should work. Konsole, Bash, and the OpenSSH client are required, and `sshpass` 1.06 or newer when the configuration holds a password target:

```bash
sudo dnf install konsole openssh-clients sshpass
```

Julia 1.10 or newer.

Clone the repository and instantiate the environments:

```bash
git clone https://github.com/PaulGoG/SshAutoLogin.jl.git
cd SshAutoLogin.jl
julia activate.jl          # root environment
julia test/activate.jl     # test environment, developed against the local source
julia format/activate.jl   # formatting environment
```

The package is not registered; run it from the clone.

## Entry points

Copy the template with mode 600 and fill in the targets. The loader refuses a configuration file that grants any permission to group or others, and git ignores every `.toml` file in the clone except the tracked ones.

```bash
install -m 600 config.example.toml config.toml
```

| Task | Command |
|---|---|
| Open all sessions | `julia scripts/run.jl` |
| Use another configuration file | `julia scripts/run.jl --config path/to/config.toml` |
| Print the emulator commands without launching | `julia scripts/run.jl --dry-run` |
| Run the test suite | `julia test/runtests.jl` |
| Format the sources | `julia format/format.jl` |
| Check formatting without writing | `julia format/format.jl --check` |

Every script activates its own environment, so `--project` is never needed. The exit status is 0 on success and 1 on any error: usage, configuration, a missing binary, or a missing runtime directory. The configuration path may be given once, as `--config PATH` or as a bare argument.

From Julia:

```julia
using SshAutoLogin
config = load_config("config.toml")
plan_sessions(config)      # emulator commands, no side effects
launch_sessions(config)    # opens the sessions and returns the emulator processes
SshAutoLogin.main(["--dry-run", "config.toml"])   # the command-line driver, in process
```

`main` returns the exit status instead of calling `exit`. It writes the dry-run listing and the `--help` text to `io` and everything else to `err`.

## Component status

| Component | Status |
|---|---|
| TOML configuration parser and field validation | Stable |
| Konsole `tabs` and `windows` layouts, `hold` option | Stable |
| Credential delivery to `sshpass` over a file descriptor | Stable |
| Key-based targets, ssh_config host aliases, `identity_file`, `proxy_jump` | Experimental |
| Terminal emulators other than Konsole | Not implemented |

## How it works

```mermaid
flowchart LR
    cfg["config.toml<br/>hosts or aliases,<br/>passwords or keys"]
    wrap["one wrapper per host<br/>fresh launch directory on tmpfs,<br/>mode 0700, self-deleting"]
    kon["Konsole<br/>one window with tabs,<br/>or one window per host"]
    t1["tab 1, ssh session"]
    tn["tab N, ssh session"]
    cfg --> wrap
    wrap --> kon
    kon --> t1
    kon --> tn
```

A password never reaches a command line or an environment, and a key target hands the launcher no secret at all; see [Security model](#security-model).

## Configuration

```toml
[globals]
connect_timeout = 10                     # integer > 0; units: s
strict_host_key_checking = "accept-new"  # one of: "accept-new" | "yes" | "no"
log_level = "ERROR"                      # OpenSSH LogLevel

[terminal]
mode = "tabs"                            # one of: "tabs" | "windows"
hold = false                             # keep the tab open after the session ends
launch_settle_timeout = 30               # finite number > 0; units: s

[[targets]]
host = "192.168.1.100"                   # host name, ssh_config Host alias, IPv4 address, or IPv6 literal
port = 22                                # optional; integer in [1, 65535]
user = "admin"                           # optional
password = "example_password_1"
title = "Cluster Node 01"                # optional; default: [user@]host[:port]
strict_host_key_checking = "accept-new"  # optional per-target override

[[targets]]
host = "hpc"                             # a Host alias of ~/.ssh/config
auth = "key"                             # one of: "password" | "key"; default "password"
identity_file = "~/.ssh/id_ed25519_hpc"  # optional, key targets only
proxy_jump = "admin@gateway.example.org" # optional; key targets, or "none" on any target
```

The parser rejects unknown keys, wrong value types, and values outside the documented constraints, and names the offending key. `host` is an RFC 1123 host name, which may also contain `_` so that ssh_config aliases pass, an IPv4 address, or an IPv6 literal without square brackets, which `ssh` does not strip. `port` and `user` are optional: a key left out is not passed to `ssh`, so `~/.ssh/config` decides, and a key set in the file overrides it. `user` starts with a letter or underscore, followed by letters, digits, `.`, `_`, or `-`, at most 32 characters in all. `title` must not contain control characters, `;`, or `%`: Konsole reads `;` as a property separator and `%` as a format placeholder.

`auth` selects how the session authenticates. A password target (`auth = "password"`, the default) needs `password`, non-empty and free of control characters. A key target (`auth = "key"`) must not carry a password: `ssh` authenticates with the agent, an identity file, a certificate, or an open master connection, as `~/.ssh/config` provides, and asks for a key passphrase or a second factor in the tab, or through the askpass program of the desktop when the session sets `SSH_ASKPASS_REQUIRE` to `prefer` or `force`. A key target may name `identity_file`, an absolute path or one starting with `~/`, free of `%` and `$` (ssh expands both in an identity path), which must be a regular file without group or other permissions, unless it is a public key (`.pub`) that selects a key held by the agent. It is passed as `-i <path> -o IdentitiesOnly=yes`: ssh offers it first, together with any `IdentityFile` of the matching `Host` block, and no other key of the agent. It may also name `proxy_jump`, passed as `ssh -J`: `[user@]host[:port]` hops separated by commas, an IPv6 address in brackets only in the last hop. `proxy_jump = "none"`, which a password target accepts as well, connects directly, whatever `ProxyJump` or `ProxyCommand` `~/.ssh/config` sets for the host.

## How a session is opened

Each launch gets a fresh directory under `$XDG_RUNTIME_DIR/ssh-autologin/` (mode 0700; the runtime directory of a systemd session is a tmpfs) holding one short Bash script per target. The script removes itself as its first action. For a password target it hands the password to `sshpass` through a pipe on file descriptor 3 and replaces itself with `sshpass -d 3 ssh ...`, with `SSH_ASKPASS_REQUIRE=never`, so that an askpass program of the desktop session cannot take the prompt from `sshpass`; for a key target it holds no secret and replaces itself with `ssh ...`. In `tabs` mode Konsole is started once with `--tabs-from-file` pointing at a list with one script per tab; in `windows` mode it is started once per target. Konsole runs in its own process (`--separate`), detached from the launcher's session, so interrupting the launcher does not reach the sessions. The launcher then waits, at most `launch_settle_timeout` seconds, until every script has removed itself, and removes the launch directory. If the emulator exits before executing every script, the directory is removed as well and a warning names the scripts left. If the wait times out while the emulator is still running, the directory is kept with a warning, and a later launch removes it once it is older than the settle timeout.

With `hold = true` the script does not replace itself: it waits for the SSH session to end, prints the exit status, and waits for Enter before the tab closes. Because this is implemented in the script rather than with Konsole's `--hold`, it applies to every tab. With `hold = false` a failed login closes the tab at once; set `hold = true` to read the error.

## Security model

The password is read from `config.toml`, which the loader refuses unless it is private to its owner, and is written into the wrapper script described above. That script sits in a directory of mode 0700 under `XDG_RUNTIME_DIR`, a tmpfs in a systemd session, and unlinks itself when executed, so it normally exists for a fraction of a second. `sshpass -d` reads the password from a pipe, so it never appears in a process environment or an argument vector (`ps`, `/proc/*/cmdline`, `/proc/*/environ`). No log record, error message, `show` rendering, or `--dry-run` listing contains a password; a syntax error in the configuration is reported by its line number, without the line. For a password target `ssh` runs with public-key authentication disabled and the preferred methods pinned to keyboard-interactive and password. An agent holding many keys therefore cannot exhaust the server's authentication attempts, and an encrypted key cannot raise a passphrase prompt that `sshpass` does not answer.

A key target hands the launcher no secret: its script carries only the `ssh` command line, and `ssh` reads the private key from the agent or from the identity file. The loader checks the mode of a configured identity file and never reads its content. A password target accepts no `proxy_jump` other than `"none"` because `sshpass` answers the first password prompt it sees: a jump host asking for a password would receive the target's password.

The threat model is a single-user workstation. A process running under the same account can read the wrapper during its short lifetime, and the package does not defend against a compromised account or a hostile administrator. Host-key verification follows the configured policy: `accept-new` (default) trusts a host on first contact and refuses a changed key, `yes` requires the key to be known already, and `no` disables verification. The policy, the connection timeout, and `identity_file` apply to the target: ssh passes none of them to a jump host, whether `proxy_jump` or `~/.ssh/config` names it, so each jump host is verified, authenticated, and timed out as its own `Host` block in `~/.ssh/config` says.

Vulnerability reports: see [SECURITY.md](SECURITY.md).

## Limitations

Linux and Konsole only. The refusal of `proxy_jump` on password targets does not extend to a `ProxyJump` or `ProxyCommand` that `~/.ssh/config` sets for the host: if that jump host asks for a password, `sshpass` gives it the target's password. Reach such hosts with a key target, or authenticate the jump host by key; a host that needs no jump host can be given `proxy_jump = "none"`.

## Repository layout

<details>
<summary>Full file tree</summary>

```
SshAutoLogin.jl/
├── .github/
│   ├── dependabot.yml         # Weekly updates of the GitHub Actions pins and the test and formatting environments
│   └── workflows/
│       ├── CI.yml             # Test suite on Julia LTS, stable, and pre-release
│       └── Format.yml         # Formatting check
├── .gitignore                 # Every .toml except the tracked ones, coverage and editor artifacts
├── .JuliaFormatter.toml       # Formatting rules (YAS style)
├── CHANGELOG.md               # Release history
├── LICENSE                    # MIT
├── Project.toml               # Package metadata and compat bounds
├── README.md
├── SECURITY.md                # Threat model and vulnerability reporting
├── activate.jl                # Activates and instantiates the root environment
├── config.example.toml        # Configuration template
├── format/
│   ├── Project.toml           # Formatting environment (JuliaFormatter 2.14)
│   ├── activate.jl            # Activates the formatting environment
│   └── format.jl              # Formats the repository; --check verifies without writing
├── scripts/
│   └── run.jl                 # Thin entry point around SshAutoLogin.main
├── src/
│   ├── SshAutoLogin.jl        # Module and exports
│   ├── validation.jl          # Field constraints and patterns
│   ├── types.jl               # SshTarget, GlobalConfig, TerminalOptions, SessionConfig
│   ├── config.jl              # TOML parsing with schema checks
│   ├── process.jl             # Wrapper scripts, emulator commands, launch logic
│   └── cli.jl                 # Command-line driver: argument parsing, main
└── test/
    ├── Project.toml           # Test environment (Aqua, JET, ExplicitImports)
    ├── activate.jl            # Activates the test environment against the local source
    └── runtests.jl            # Static analysis, unit tests, launches against a stub emulator, command-line scenarios
```

</details>

## License

MIT, see [LICENSE](LICENSE).
