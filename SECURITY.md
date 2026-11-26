# Security policy

## Scope

SshAutoLogin opens interactive SSH sessions, authenticated with passwords read from a local TOML file or by `ssh` itself with keys. It assumes a single-user workstation: the loader refuses a configuration file that anyone but its owner can access, and every process that handles the password runs under the same account. It does not protect against a compromised account, a hostile administrator, or a compromised remote host.

## Handling of credentials

The password is read from `config.toml` into memory. Each launch creates a directory of mode 0700 under `$XDG_RUNTIME_DIR/ssh-autologin/`, which is user-private and a tmpfs under systemd, and writes one wrapper script per target into it, also with mode 0700. The script holds the password and unlinks itself as its first action. The password reaches `ssh` through `sshpass -d`, over a pipe on a private file descriptor, never through the environment or a command-line argument. For a password target `ssh` runs with public-key authentication disabled and one password prompt. A key target hands the package no secret: its wrapper carries only the `ssh` command line, and `ssh` reads the key from the agent or from the identity file, whose mode the loader checks without reading it. Log messages, `--dry-run` output, error messages, and `show` of configuration objects never contain a password; a syntax error in the configuration file is reported by its line number, without the line.

## Known limitations

Any process running under the same account can read the wrapper during the short interval between creation and execution. A wrapper that the emulator has not executed when the settle timeout elapses stays in the launch directory until a later launch purges it or the session ends. The host-key policy `no` disables man-in-the-middle protection; the default `accept-new` trusts a host on first contact. `sshpass` answers the first password prompt it sees: a password target is therefore refused a `proxy_jump` other than `"none"`, but a jump host that `~/.ssh/config` sets for it and that asks for a password receives the target's password. The host-key policy and the other options of the package apply to the target only; jump hosts are verified as their own entries in `~/.ssh/config` say.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository, or write to me at the address in `Project.toml`. Please do not open a public issue for an undisclosed vulnerability.
