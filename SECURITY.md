# Security policy

## Scope

SshAutoLogin opens interactive SSH sessions with password authentication read from a local TOML file. The threat model is a single-user workstation: the configuration file is readable only by its owner, and every process that handles the password runs under the same account. The package does not protect against a compromised account, a hostile administrator, or a compromised remote host.

## Handling of credentials

The password is read from `config.toml` into memory. For each target a wrapper script containing the password is written to `$XDG_RUNTIME_DIR/ssh-autologin/`, a user-private tmpfs directory (mode 0700); the script has mode 0700 and unlinks itself as its first action when executed. The password reaches `ssh` through `sshpass -d`, that is through a pipe on a private file descriptor, never through the environment or a command-line argument. Log messages, `--dry-run` output, error messages, and `show` of configuration objects never contain a password.

## Known limitations

If `XDG_RUNTIME_DIR` is unset, the wrapper scripts are written to a temporary directory on the regular file system and a warning is printed. Any process running under the same account can read the wrapper during the short interval between creation and execution. The host-key policy `no` disables man-in-the-middle protection; the default `accept-new` trusts a host on first contact.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository, or write to the maintainer address listed in `Project.toml`. Please do not open a public issue for an undisclosed vulnerability.
