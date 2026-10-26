# Security policy

## Scope

SshAutoLogin opens interactive SSH sessions with passwords read from a local TOML file. The threat model is a single-user workstation: the configuration file is readable only by its owner, which the loader enforces, and every process that handles the password runs under the same account. The package does not protect against a compromised account, a hostile administrator, or a compromised remote host.

## Handling of credentials

The password is read from `config.toml` into memory. For each launch a directory of mode 0700 is created under `$XDG_RUNTIME_DIR/ssh-autologin/`, a user-private tmpfs directory, and one wrapper script per target, containing the password, is written into it with mode 0700; the script unlinks itself as its first action when executed. The password reaches `ssh` through `sshpass -d`, that is, through a pipe on a private file descriptor, never through the environment or a command-line argument. `ssh` runs with public-key authentication disabled and one password prompt. Log messages, `--dry-run` output, error messages, and `show` of configuration objects never contain a password.

## Known limitations

Any process running under the same account can read the wrapper during the short interval between creation and execution. A wrapper that the emulator has not executed when the settle timeout elapses stays in the launch directory until a later launch purges it or the session ends. The host-key policy `no` disables man-in-the-middle protection; the default `accept-new` trusts a host on first contact.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository, or write to the maintainer address listed in `Project.toml`. Do not open a public issue for an undisclosed vulnerability.
