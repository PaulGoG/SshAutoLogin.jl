# SshAutoLogin.jl

Automated multi-session SSH terminal orchestrator tailored for Fedora Linux and KDE Plasma (`konsole`).

```
SshAutoLogin/
├── .gitignore               # Credential and artifact exclusions
├── .JuliaFormatter.toml     # Formatting rules (YAS style)
├── Project.toml             # Root package definition and stdlib compat
├── activate.jl              # Pure-Julia root environment activation script
├── config.example.toml      # Reference TOML configuration template
├── README.md                # Package documentation and architecture guide
├── src/
│   ├── SshAutoLogin.jl      # Root module entry point and public exports
│   ├── types.jl             # Concrete immutable data structures
│   ├── validation.jl        # Strict parameter and schema validation logic
│   ├── config.jl            # TOML parser and configuration mapper
│   └── process.jl           # Command constructor and async process dispatcher
├── scripts/
│   └── run.jl               # CLI driver script
└── test/
    ├── Project.toml         # Test environment dependencies (Aqua, JET, etc.)
    ├── activate.jl          # Test environment activation script
    └── runtests.jl          # QA and unit test suite
```

---

## 1. System Requirements

- **Operating System:** Linux (Fedora 40+ / KDE Plasma)
- **Terminal Emulator:** KDE Konsole (`/usr/bin/konsole`)
- **Core Utilities:** OpenSSH client (`ssh`), `sshpass`
  ```bash
  sudo dnf install -y sshpass
  ```
- **Julia Runtime:** Julia ≥ 1.10

---

## 2. Architectural Design & Security

### Secure Credential Injection
Standard OpenSSH enforces direct interactive TTY authentication. To automate multi-session tab launching without exposing plaintext credentials to `/proc/*/cmdline` (`ps aux`), `SshAutoLogin.jl` injects passwords through the `SSHPASS` environment variable coupled with `sshpass -e`:
```bash
SSHPASS="<secret>" konsole --new-tab -p tabtitle="<title>" -e sshpass -e ssh -p <port> <user>@<host>
```

### Configurable Host Key Policy
Host key verification is configurable globally and overridable per target in the TOML configuration:
- `"accept-new"` *(Default & Recommended)*: Automatically trusts and saves new remote host keys to `~/.ssh/known_hosts` (Trust-On-First-Use), while strictly refusing connection if a known key has changed (full MITM protection).
- `"yes"`: Enforces strict host key checking. Connection aborts or prompts if host key is absent.
- `"no"`: Disables host key verification (suitable only for ephemeral testing clusters).

### Asynchronous Tab Multiplexing
Sessions are launched asynchronously with minimal inter-process delays (`tab_delay = 0.2s`) to ensure the KDE Plasma D-Bus server reliably registers tab ordering within a single Konsole window.

---

## 3. Configuration Specification

Create a `config.toml` file (see [`config.example.toml`](file:///path/to/workspace/config.example.toml)):

```toml
[globals]
# SSH connection timeout in seconds
connect_timeout = 10  # integer > 0; units: s

# SSH host key verification policy
strict_host_key_checking = "accept-new"  # one of: "accept-new" | "yes" | "no"

# OpenSSH log verbosity level
log_level = "ERROR"  # one of: "QUIET" | "FATAL" | "ERROR" | "INFO" | "VERBOSE" | "DEBUG"

[terminal]
# Target terminal emulator executable
emulator = "konsole"  # one of: "konsole"

# Window aggregation mode
mode = "tabs"  # one of: "tabs" | "windows"

# Retain terminal tab after SSH process exits
hold = false  # one of: true | false

[[targets]]
host = "192.168.1.100"
port = 22
user = "admin"
password = "target_password_1"
title = "Cluster Node 01"

[[targets]]
host = "192.168.1.101"
port = 2222
user = "developer"
password = "target_password_2"
title = "Dev Gateway"
strict_host_key_checking = "accept-new"
```

---

## 4. Usage

### Launching Sessions
To dispatch all configured SSH sessions into tabs in a single Konsole window:
```bash
julia --project=. scripts/run.jl --config config.toml
```

### Dry Run Inspection
To inspect constructed commands and environment variables without launching terminal windows:
```bash
julia --project=. scripts/run.jl --config config.toml --dry-run
```

---

## 5. Verification & Testing

Activate and execute the test suite (comprising Aqua.jl static analysis, JET.jl type stability checks, ExplicitImports.jl linting, and full unit test coverage):
```bash
julia test/activate.jl
julia --project=test test/runtests.jl
```
