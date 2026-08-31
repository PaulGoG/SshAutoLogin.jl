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
    get_runtime_directory()::String

Resolve and initialize a secure, user-private in-memory runtime directory (`XDG_RUNTIME_DIR`).
"""
function get_runtime_directory()::String
    base_dir = get(ENV, "XDG_RUNTIME_DIR", joinpath(homedir(), ".cache"))
    dir_path = joinpath(base_dir, "ssh-autologin")
    mkpath(dir_path)
    chmod(dir_path, 0o700)
    return dir_path
end

"""
    build_single_window_command(
        target::SshTarget,
        globals::GlobalConfig,
        terminal::TerminalOptions,
    )::Cmd

Construct a command to spawn an independent single Konsole window.
"""
function build_single_window_command(target::SshTarget,
                                     globals::GlobalConfig,
                                     terminal::TerminalOptions)::Cmd
    policy = resolve_host_key_policy(target, globals)

    cmd_args = String[terminal.emulator, "--separate"]
    if terminal.hold
        push!(cmd_args, "--hold")
    end

    push!(cmd_args, "-p", "tabtitle=$(target.title)")
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

    target_env = merge(copy(ENV), Dict("SSHPASS" => target.password))
    base_cmd = Cmd(cmd_args)
    return setenv(base_cmd, target_env)
end

"""
    generate_target_wrapper_script(
        target::SshTarget,
        globals::GlobalConfig,
    )::String

Generate the content of a secure shell wrapper script for a given target.
"""
function generate_target_wrapper_script(target::SshTarget,
                                        globals::GlobalConfig)::String
    policy = resolve_host_key_policy(target, globals)
    escaped_password = replace(target.password, '\'' => "'\\''")

    return """
    #!/bin/bash
    export SSHPASS='$(escaped_password)'
    exec sshpass -e ssh -p $(target.port) -o StrictHostKeyChecking=$(policy) -o ConnectTimeout=$(globals.connect_timeout) -o LogLevel=$(globals.log_level) $(target.user)@$(target.host)
    """
end

"""
    generate_tabs_file_content(
        targets::AbstractVector{SshTarget},
        wrapper_paths::AbstractVector{<:AbstractString},
    )::String

Generate the content of a Konsole tabs definition file referencing executable wrapper scripts.
"""
function generate_tabs_file_content(targets::AbstractVector{SshTarget},
                                    wrapper_paths::AbstractVector{<:AbstractString})::String
    lines = String[]
    for (target, wrapper_path) in zip(targets, wrapper_paths)
        push!(lines, "title: $(target.title) ;; command: $(wrapper_path)")
    end
    return join(lines, "\n") * "\n"
end

"""
    build_tabs_launch_command(
        config::SessionConfig,
        tabs_file_path::AbstractString,
    )::Cmd

Construct the Konsole invocation command to launch all tabs in a single window via `--tabs-from-file`.
"""
function build_tabs_launch_command(config::SessionConfig,
                                   tabs_file_path::AbstractString)::Cmd
    cmd_args = String[config.terminal.emulator, "--nofork", "--tabs-from-file",
                      tabs_file_path]
    if config.terminal.hold
        push!(cmd_args, "--hold")
    end
    return Cmd(cmd_args)
end

"""
    launch_all_sessions(
        config::SessionConfig;
        dry_run::Bool = false,
    )::Vector{Union{Cmd, Base.Process}}

Spawn terminal sessions for all targets. In `:tabs` mode, creates all tabs within a single Konsole window.
In `:windows` mode, spawns individual windows for each target.
"""
function launch_all_sessions(config::SessionConfig;
                             dry_run::Bool=false)::Vector{Union{Cmd, Base.Process}}
    if !dry_run
        check_prerequisites(config.terminal)
    end

    if config.terminal.mode == :tabs
        if dry_run
            @info "Constructed tabs configuration for single-window launch" total_tabs=length(config.targets)
            pseudo_cmd = build_tabs_launch_command(config, "<generated-tabs-file>")
            return Union{Cmd, Base.Process}[pseudo_cmd]
        end

        session_dir = get_runtime_directory()

        wrapper_paths = String[]
        for (idx, target) in enumerate(config.targets)
            wrapper_file = joinpath(session_dir, "target_$(idx).sh")
            open(wrapper_file, "w") do io
                return write(io, generate_target_wrapper_script(target, config.globals))
            end
            chmod(wrapper_file, 0o700)
            push!(wrapper_paths, wrapper_file)
        end

        tabs_path = joinpath(session_dir, "tabs.konsole")
        open(tabs_path, "w") do io
            return write(io, generate_tabs_file_content(config.targets, wrapper_paths))
        end
        chmod(tabs_path, 0o600)

        cmd = build_tabs_launch_command(config, tabs_path)
        @info "Launching single Konsole window with tabs" total_tabs=length(config.targets) tabs_file=tabs_path
        proc = run(cmd; wait=false)
        return Union{Cmd, Base.Process}[proc]
    else
        processes = Union{Cmd, Base.Process}[]
        for target in config.targets
            cmd = build_single_window_command(target, config.globals, config.terminal)
            @info "Spawning window session" host=target.host port=target.port user=target.user title=target.title dry_run=dry_run
            if dry_run
                push!(processes, cmd)
            else
                push!(processes, run(cmd; wait=false))
            end
        end
        return processes
    end
end
