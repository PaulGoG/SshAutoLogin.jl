"""
    check_prerequisites(terminal::TerminalOptions)

Verify that the required system binaries (`ssh`, `sshpass`, and the terminal emulator) exist in `PATH`.
Throws `ErrorException` if any prerequisite is missing.
"""
function check_prerequisites(terminal::TerminalOptions)
    required_binaries = ["ssh", "sshpass", terminal.emulator]
    missing_binaries = filter(bin -> Sys.which(bin) === nothing, required_binaries)
    if !isempty(missing_binaries)
        throw(ErrorException("Missing required system binaries in PATH: $(join(missing_binaries, ", ")). " *
                             "Please ensure they are installed (e.g. 'sudo dnf install sshpass')."))
    end
    return nothing
end

"""
    resolve_host_key_policy(target::SshTarget, globals::GlobalConfig)::String

Determine the effective host key verification policy for a given target, respecting overrides.
"""
function resolve_host_key_policy(target::SshTarget, globals::GlobalConfig)::String
    return target.strict_host_key_checking !== nothing ? target.strict_host_key_checking :
           globals.strict_host_key_checking
end

"""
    build_terminal_command(
        target::SshTarget,
        globals::GlobalConfig,
        terminal::TerminalOptions;
        is_first::Bool = false,
    )::Cmd

Construct the full terminal execution `Cmd` with `SSHPASS` credential injection.

# Arguments
- `target::SshTarget`: Target host parameters.
- `globals::GlobalConfig`: Global connection options.
- `terminal::TerminalOptions`: Terminal manager settings.
- `is_first::Bool`: Whether this invocation is the first tab in the session batch.

# Returns
- `Cmd`: Configured command object with injected environment variable.
"""
function build_terminal_command(target::SshTarget,
                                globals::GlobalConfig,
                                terminal::TerminalOptions;
                                is_first::Bool=false)::Cmd
    policy = resolve_host_key_policy(target, globals)

    # Construct base Konsole arguments
    cmd_args = String[terminal.emulator]

    if terminal.mode == :tabs && !is_first
        push!(cmd_args, "--new-tab")
    end

    if terminal.hold
        push!(cmd_args, "--hold")
    end

    # Profile property for tab title
    push!(cmd_args, "-p", "tabtitle=$(target.title)")

    # Execution payload (-e must be the final option for konsole)
    push!(cmd_args,
          "-e",
          "sshpass",
          "-e",
          "ssh",
          "-p",
          string(target.port),
          "-o",
          "StrictHostKeyChecking=$(policy)",
          "-o",
          "ConnectTimeout=$(globals.connect_timeout)",
          "-o",
          "LogLevel=$(globals.log_level)",
          "$(target.user)@$(target.host)")

    # Wrap in Cmd and attach SSHPASS to the process environment
    base_cmd = Cmd(cmd_args)
    return setenv(base_cmd, "SSHPASS" => target.password)
end

"""
    launch_session(
        target::SshTarget,
        globals::GlobalConfig,
        terminal::TerminalOptions;
        is_first::Bool = false,
        dry_run::Bool = false,
    )::Union{Cmd, Base.Process}

Launch an individual SSH session in a new terminal tab or window.
"""
function launch_session(target::SshTarget,
                        globals::GlobalConfig,
                        terminal::TerminalOptions;
                        is_first::Bool=false,
                        dry_run::Bool=false)::Union{Cmd, Base.Process}
    cmd = build_terminal_command(target, globals, terminal; is_first=is_first)

    @info "Spawning session" host=target.host port=target.port user=target.user title=target.title mode=terminal.mode is_first=is_first dry_run=dry_run

    if dry_run
        return cmd
    end

    return run(cmd; wait=false)
end

"""
    launch_all_sessions(
        config::SessionConfig;
        dry_run::Bool = false,
        tab_delay::Real = 0.2,
    )::Vector{Union{Cmd, Base.Process}}

Iterate and asynchronously spawn terminal tabs for all targets defined in [`SessionConfig`](@ref).
"""
function launch_all_sessions(config::SessionConfig;
                             dry_run::Bool=false,
                             tab_delay::Real=0.2)::Vector{Union{Cmd, Base.Process}}
    if !dry_run
        check_prerequisites(config.terminal)
    end

    processes = Union{Cmd, Base.Process}[]
    for (idx, target) in enumerate(config.targets)
        is_first = (idx == 1)
        proc = launch_session(target,
                              config.globals,
                              config.terminal;
                              is_first=is_first,
                              dry_run=dry_run)
        push!(processes, proc)

        # Allow Konsole D-Bus registration between rapid successive tab requests
        if !dry_run && config.terminal.mode == :tabs && idx < length(config.targets)
            sleep(tab_delay)
        end
    end

    return processes
end
