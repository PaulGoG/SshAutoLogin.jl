#!/usr/bin/env julia

using Pkg
const PROJECT_ROOT = dirname(@__DIR__)
Pkg.activate(PROJECT_ROOT; io=devnull)
Pkg.instantiate(; io=devnull)

using SshAutoLogin

"""
    print_usage()

Print the command-line usage summary.
"""
function print_usage()
    return println("""
                   Usage: julia scripts/run.jl [OPTIONS] [CONFIG_FILE]

                   Open one terminal tab or window per target listed in the TOML configuration.

                   Options:
                     -c, --config PATH    Configuration file (default: config.toml next to the project)
                     -d, --dry-run        Print the emulator commands without writing or launching anything
                     -h, --help           Show this message and exit
                   """)
end

"""
    parse_cli_args(args::Vector{String})

Return `(config_path, dry_run)` parsed from `args`; exits on usage errors.
"""
function parse_cli_args(args::Vector{String})
    config_path = joinpath(PROJECT_ROOT, "config.toml")
    dry_run = false
    index = 1
    while index <= length(args)
        arg = args[index]
        if arg in ("-h", "--help")
            print_usage()
            exit(0)
        elseif arg in ("-d", "--dry-run")
            dry_run = true
            index += 1
        elseif arg in ("-c", "--config")
            if index + 1 > length(args)
                println(stderr, "Error: $(arg) requires a path argument.")
                exit(1)
            end
            config_path = args[index + 1]
            index += 2
        elseif startswith(arg, "-")
            println(stderr, "Error: unrecognized option '$(arg)'.")
            print_usage()
            exit(1)
        else
            config_path = arg
            index += 1
        end
    end
    return config_path, dry_run
end

function main(args::Vector{String}=ARGS)
    config_path, dry_run = parse_cli_args(args)
    if !isfile(config_path)
        println(stderr, "Error: configuration file not found at '$(config_path)'.")
        println(stderr, "Create one from the template: cp config.example.toml config.toml")
        exit(1)
    end

    config = try
        load_config(config_path)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "Error: ", sprint(showerror, err))
        exit(1)
    end

    @info "Session configuration loaded" path=config_path targets=length(config.targets) mode=config.terminal.mode dry_run
    for (index, target) in enumerate(config.targets)
        @info "Target" index host=target.host port=target.port user=target.user title=target.title
    end

    if dry_run
        println("Emulator commands (dry run; '<runtime-dir>' stands for the runtime directory):")
        for cmd in plan_sessions(config)
            println("  ", command_string(cmd))
        end
        return nothing
    end

    processes = try
        launch_sessions(config)
    catch err
        err isa MissingBinaryError || rethrow()
        println(stderr, "Error: ", sprint(showerror, err))
        exit(1)
    end
    @info "Sessions dispatched" emulator_processes=length(processes)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
