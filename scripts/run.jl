#!/usr/bin/env julia

using Logging
using SshAutoLogin

function parse_cli_args(args::Vector{String})
    config_file = joinpath(dirname(@__DIR__), "config.toml")
    dry_run = false

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("-h", "--help")
            println("Usage: julia --project scripts/run.jl [OPTIONS] [CONFIG_FILE]")
            println()
            println("Options:")
            println("  -c, --config PATH    Path to TOML configuration file (default: config.toml)")
            println("  -d, --dry-run        Print constructed terminal commands without launching")
            println("  -h, --help           Show this help message and exit")
            exit(0)
        elseif arg in ("-d", "--dry-run")
            dry_run = true
            i += 1
        elseif arg in ("-c", "--config")
            if i + 1 > length(args)
                @error "Missing argument for $(arg)"
                exit(1)
            end
            config_file = args[i + 1]
            i += 2
        elseif startswith(arg, "-")
            @error "Unrecognized command line argument: $(arg)"
            exit(1)
        else
            config_file = arg
            i += 1
        end
    end

    return config_file, dry_run
end

function main()
    config_path, dry_run = parse_cli_args(ARGS)

    if !isfile(config_path)
        @error "Configuration file does not exist" path=config_path
        @info "Create a valid configuration file or copy 'config.example.toml':"
        @info "  cp config.example.toml config.toml"
        exit(1)
    end

    @info "Loading SSH session configuration" path=config_path dry_run=dry_run
    config = try
        load_config(config_path)
    catch err
        @error "Configuration loading failed" exception=(err, catch_backtrace())
        exit(1)
    end

    @info "Dispatching SSH terminal sessions" total_targets=length(config.targets) mode=config.terminal.mode
    try
        processes = launch_all_sessions(config; dry_run=dry_run)
        if dry_run
            println("\n--- Constructed Commands (Dry Run) ---")
            for (idx, cmd) in enumerate(processes)
                println("Target #$(idx): $(cmd)")
            end
        else
            @info "All sessions successfully dispatched into $(config.terminal.emulator)."
        end
    catch err
        @error "Execution failed during session dispatch" exception=(err, catch_backtrace())
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
