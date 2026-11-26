"""
    MissingBinaryError

Thrown when a required executable (`bash`, `ssh`, `konsole`, and `sshpass` when a
password target is present) is not found in `PATH`.
"""
struct MissingBinaryError <: Exception
    binaries::Vector{String}
end

function Base.showerror(io::IO, err::MissingBinaryError)
    return print(io, "Required system binaries not found in PATH: ",
                 join(err.binaries, ", "),
                 ". Install them (Fedora: 'sudo dnf install bash sshpass openssh-clients konsole').")
end

"""
    check_prerequisites(targets::AbstractVector{SshTarget})

Throw [`MissingBinaryError`](@ref) unless `bash` (the wrapper scripts are Bash), `ssh`,
and `konsole` are all found in `PATH`, together with `sshpass` when any of `targets`
uses `auth = :password`.
"""
function check_prerequisites(targets::AbstractVector{SshTarget})
    required = ["bash", "ssh"]
    any(t -> t.auth == :password, targets) && push!(required, "sshpass")
    push!(required, KONSOLE)
    missing_binaries = filter(name -> Sys.which(name) === nothing, required)
    isempty(missing_binaries) || throw(MissingBinaryError(missing_binaries))
    return nothing
end

"""
    resolve_host_key_policy(target::SshTarget, globals::GlobalConfig)::String

Return the per-target host-key policy override when set, otherwise the global policy.
"""
function resolve_host_key_policy(target::SshTarget, globals::GlobalConfig)::String
    override = target.strict_host_key_checking
    return override === nothing ? globals.strict_host_key_checking : override
end

"""
    command_string(cmd::Cmd)::String

Render the argument vector of `cmd` as a POSIX-shell-quoted string. The environment of
`cmd` is not rendered, so the result is safe to print or log.
"""
command_string(cmd::Cmd)::String = Base.shell_escape_posixly(cmd.exec...)

# Executable of the terminal emulator.
const KONSOLE = "konsole"
const LAUNCH_PREFIX = "launch-"
const TABS_FILE = "tabs.konsole"

wrapper_name(index::Integer)::String = "target_$(index).sh"

"""
    runtime_directory()::String

`\$XDG_RUNTIME_DIR/ssh-autologin`, created if needed and set to mode `0700`. The wrapper
scripts hold passwords; under a systemd user session `XDG_RUNTIME_DIR` is user-private
and in memory. Throws `ArgumentError` when the variable is unset or does not name a
directory.
"""
function runtime_directory()::String
    base = get(ENV, "XDG_RUNTIME_DIR", "")
    if isempty(base) || !isdir(base)
        throw(ArgumentError("XDG_RUNTIME_DIR is unset or is not a directory. The wrapper scripts hold passwords and are written only to the runtime directory of a systemd user session; log in graphically or export XDG_RUNTIME_DIR."))
    end
    directory = joinpath(base, "ssh-autologin")
    mkpath(directory)
    chmod(directory, 0o700)
    return directory
end

"""
    purge_stale_launches!(directory::AbstractString, max_age_seconds::Real)

Remove every launch directory below `directory` whose last modification lies more than
`max_age_seconds` in the past. A launch directory outlives its launch only when the
emulator did not execute every wrapper within the settle timeout; once it is older than
that timeout, no launcher is waiting on it.
"""
function purge_stale_launches!(directory::AbstractString, max_age_seconds::Real)
    now = time()
    for entry in readdir(directory; join=true)
        startswith(basename(entry), LAUNCH_PREFIX) || continue
        now - mtime(entry) > max_age_seconds || continue
        rm(entry; recursive=true, force=true)
    end
    return nothing
end

"""
    ssh_arguments(target::SshTarget, globals::GlobalConfig)::Vector{String}

Return the `ssh` argument vector for `target`: the port when set, the resolved host-key
policy, the connection timeout, the log level, the options of the authentication mode,
and the destination `[user@]host`. Unset port and user are left to ~/.ssh/config.

For `auth = :password`, public-key authentication is disabled, the preferred methods are
pinned to keyboard-interactive and password, and a single password prompt is allowed, so
that an agent holding many keys cannot exhaust the server's authentication attempts and
an encrypted key cannot trigger a passphrase prompt that `sshpass` does not answer.

For `auth = :key`, no method is pinned: `ssh` proceeds as ~/.ssh/config directs, and any
prompt (key passphrase, second factor) is answered in the tab. A set `identity_file` is
passed as `-i <path> -o IdentitiesOnly=yes`, a set `proxy_jump` as `-J <spec>`.
"""
function ssh_arguments(target::SshTarget, globals::GlobalConfig)::Vector{String}
    policy = resolve_host_key_policy(target, globals)
    arguments = String["ssh"]
    target.port === nothing || append!(arguments, ("-p", string(target.port)))
    append!(arguments,
            ("-o", "StrictHostKeyChecking=$(policy)", "-o",
             "ConnectTimeout=$(globals.connect_timeout)", "-o",
             "LogLevel=$(globals.log_level)"))
    if target.auth == :password
        append!(arguments,
                ("-o", "PubkeyAuthentication=no", "-o",
                 "PreferredAuthentications=keyboard-interactive,password", "-o",
                 "NumberOfPasswordPrompts=1"))
    else
        if target.identity_file !== nothing
            append!(arguments, ("-i", target.identity_file, "-o", "IdentitiesOnly=yes"))
        end
        target.proxy_jump === nothing || append!(arguments, ("-J", target.proxy_jump))
    end
    push!(arguments, target_label(target.host, target.user))
    return arguments
end

"""
    generate_target_wrapper_script(target::SshTarget, globals::GlobalConfig;
                                   hold::Bool=false)::String

Return the text of the Bash wrapper that opens the SSH session for `target`.

The script unlinks itself as its first action. For `auth = :password` it exposes the
password to `sshpass` through file descriptor 3 (a pipe fed by a process substitution,
so the secret appears in no environment or argument vector) and replaces itself with
`sshpass -d 3 ssh ...`. For `auth = :key` it holds no secret and replaces itself with
`ssh ...`. With `hold = true` the script instead waits for the session to end, prints
its exit status, and waits for Enter before the tab closes. Every interpolated value is
quoted with `Base.shell_escape_posixly`.
"""
function generate_target_wrapper_script(target::SshTarget, globals::GlobalConfig;
                                        hold::Bool=false)::String
    if target.auth == :key
        key_command = Base.shell_escape_posixly(ssh_arguments(target, globals)...)
        key_header = """
                     #!/usr/bin/env bash
                     # Generated by SshAutoLogin.jl; removed from the file system on first execution.
                     rm -f -- "\$0"
                     """
        if hold
            return key_header * """
                                $(key_command)
                                status=\$?
                                printf '\\nSSH session ended with exit status %d. Press Enter to close this tab.\\n' "\$status"
                                read -r _
                                """
        end
        return key_header * "exec $(key_command)\n"
    end
    # A password target always holds a password; the constructor refuses one without.
    quoted_password = Base.shell_escape_posixly(target.password::String)
    session_command = Base.shell_escape_posixly("sshpass", "-d", "3",
                                                ssh_arguments(target, globals)...)
    header = """
             #!/usr/bin/env bash
             # Generated by SshAutoLogin.jl; removed from the file system on first execution.
             rm -f -- "\$0"
             exec 3< <(printf -- '%s\\n' $(quoted_password))
             """
    if hold
        return header * """
                        $(session_command)
                        status=\$?
                        exec 3<&-
                        printf '\\nSSH session ended with exit status %d. Press Enter to close this tab.\\n' "\$status"
                        read -r _
                        """
    end
    return header * "exec $(session_command)\n"
end

"""
    generate_tabs_file_content(targets, wrapper_paths)::String

Return the Konsole `--tabs-from-file` specification: one `title: ... ;; command: ...`
line per target, each command being the target's wrapper script.
"""
function generate_tabs_file_content(targets::AbstractVector{SshTarget},
                                    wrapper_paths::AbstractVector{<:AbstractString})::String
    length(targets) == length(wrapper_paths) ||
        throw(DimensionMismatch("$(length(targets)) targets but $(length(wrapper_paths)) wrapper paths."))
    buffer = IOBuffer()
    for (target, path) in zip(targets, wrapper_paths)
        println(buffer, "title: ", target.title, " ;; command: ", path)
    end
    return String(take!(buffer))
end

"""
    build_tabs_launch_command(tabs_file_path::AbstractString)::Cmd

Return the command that opens one emulator window with all tabs described in
`tabs_file_path`. `--separate` runs Konsole in its own process instead of handing the
request to a running instance, so the returned process is the emulator itself and its
exit is visible to the settle wait.
"""
function build_tabs_launch_command(tabs_file_path::AbstractString)::Cmd
    return Cmd(String[KONSOLE, "--separate", "--tabs-from-file", tabs_file_path])
end

"""
    build_single_window_command(target::SshTarget, wrapper_path::AbstractString)::Cmd

Return the command that opens a separate emulator window running the wrapper script of
`target`, with `--separate` as in [`build_tabs_launch_command`](@ref).
"""
function build_single_window_command(target::SshTarget, wrapper_path::AbstractString)::Cmd
    return Cmd(String[KONSOLE, "--separate", "-p", "tabtitle=$(target.title)", "-e",
                      wrapper_path])
end

"""
    emulator_commands(config::SessionConfig, directory::AbstractString)::Vector{Cmd}

The emulator commands of a launch whose files live in `directory`: one tabs command, or
one window command per target.
"""
function emulator_commands(config::SessionConfig, directory::AbstractString)::Vector{Cmd}
    if config.terminal.mode == :tabs
        return Cmd[build_tabs_launch_command(joinpath(directory, TABS_FILE))]
    end
    return Cmd[build_single_window_command(target,
                                           joinpath(directory, wrapper_name(index)))
               for (index, target) in enumerate(config.targets)]
end

"""
    plan_sessions(config::SessionConfig)::Vector{Cmd}

Return the emulator commands that [`launch_sessions`](@ref) would execute, with the
launch directory replaced by the placeholder `<runtime-dir>`. Nothing is written or
executed, and the result contains no credentials.
"""
plan_sessions(config::SessionConfig)::Vector{Cmd} = emulator_commands(config,
                                                                      "<runtime-dir>")

"""
    write_private_file(path::AbstractString, content::AbstractString, mode::Integer)

Create `path` empty with permission `mode`, then write `content`. The launch directory,
mode `0700`, is what keeps the content private; the file mode is a second barrier.
"""
function write_private_file(path::AbstractString, content::AbstractString, mode::Integer)
    touch(path)
    chmod(path, mode)
    open(path, "w") do io
        return write(io, content)
    end
    return path
end

"""
    write_wrapper_scripts(config::SessionConfig, directory::AbstractString)::Vector{String}

Write one executable (mode `0700`) wrapper script per target into `directory` and return
their paths in target order.
"""
function write_wrapper_scripts(config::SessionConfig,
                               directory::AbstractString)::Vector{String}
    paths = String[]
    for (index, target) in enumerate(config.targets)
        path = joinpath(directory, wrapper_name(index))
        content = generate_target_wrapper_script(target, config.globals;
                                                 hold=config.terminal.hold)
        write_private_file(path, content, 0o700)
        push!(paths, path)
    end
    return paths
end

"""
    await_wrapper_consumption(wrapper_paths, processes, timeout_seconds::Real)::Bool

Poll until every wrapper script has unlinked itself (which each does on execution),
until every emulator process has exited, or until `timeout_seconds` elapse on the
monotonic clock. Return whether all wrappers were consumed.
"""
function await_wrapper_consumption(wrapper_paths::AbstractVector{<:AbstractString},
                                   processes::AbstractVector{Base.Process},
                                   timeout_seconds::Real)::Bool
    start = time_ns()
    while (time_ns() - start) / 1e9 < timeout_seconds
        all(!isfile, wrapper_paths) && return true
        all(process_exited, processes) && break
        sleep(0.05)
    end
    return all(!isfile, wrapper_paths)
end

"""
    start_emulator(cmd::Cmd)::Base.Process

Start `cmd` in its own session with its standard streams on `/dev/null`: an interrupt of
the launcher does not reach the emulator, and the emulator's diagnostics do not land in
the launcher's terminal.
"""
function start_emulator(cmd::Cmd)::Base.Process
    return run(pipeline(detach(cmd); stdin=devnull, stdout=devnull, stderr=devnull);
               wait=false)
end

"""
    launch_sessions(config::SessionConfig)::Vector{Base.Process}

Open the SSH sessions of `config` in the terminal emulator and return the emulator
processes (one for `:tabs` mode, one per target for `:windows` mode).

Each launch gets a fresh directory below the runtime directory (see
[`runtime_directory`](@ref)); directories left by earlier launches are removed once
they are older than `launch_settle_timeout`. The wrapper scripts are written there, the
emulator is started, and the function waits, at most `config.terminal.launch_settle_timeout`
seconds, until every wrapper has removed itself. The launch directory is then removed. It
is also removed, with a warning, when every emulator process has exited without
executing every wrapper, because nothing is left to consume them. If the wait times out
while an emulator is still running, the directory is kept, with a warning, and a later
launch purges it.
"""
function launch_sessions(config::SessionConfig)::Vector{Base.Process}
    check_prerequisites(config.targets)
    base = runtime_directory()
    purge_stale_launches!(base, config.terminal.launch_settle_timeout)
    directory = mktempdir(base; prefix=LAUNCH_PREFIX, cleanup=false)
    wrapper_paths = write_wrapper_scripts(config, directory)
    if config.terminal.mode == :tabs
        write_private_file(joinpath(directory, TABS_FILE),
                           generate_tabs_file_content(config.targets, wrapper_paths), 0o600)
        @info "Launching terminal window" tabs=length(config.targets)
    else
        for target in config.targets
            @info "Launching terminal window" host=target.host port=target.port user=target.user title=target.title
        end
    end
    processes = Base.Process[start_emulator(cmd)
                             for cmd in emulator_commands(config, directory)]

    consumed = await_wrapper_consumption(wrapper_paths, processes,
                                         config.terminal.launch_settle_timeout)
    if consumed
        rm(directory; recursive=true, force=true)
    elseif all(process_exited, processes)
        remaining = basename.(filter(isfile, wrapper_paths))
        exit_codes = [p.exitcode for p in processes]
        rm(directory; recursive=true, force=true)
        @warn "The emulator exited before executing every wrapper script; the launch directory was removed" emulator_exit_codes=exit_codes remaining
    else
        remaining = basename.(filter(isfile, wrapper_paths))
        @warn "Not every wrapper script was executed within the settle timeout; the launch directory is kept until a later launch purges it" directory timeout_seconds=config.terminal.launch_settle_timeout remaining
    end
    return processes
end
