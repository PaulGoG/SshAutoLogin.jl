"""
    CliOptions

Parsed command line of the driver.

# Fields
- `help::Bool`: print the usage text and do nothing else.
- `config_path::String`: configuration file to load.
- `dry_run::Bool`: print the emulator commands without writing or launching anything.
"""
struct CliOptions
    help::Bool
    config_path::String
    dry_run::Bool
end

"""
    default_config_path()::String

`config.toml` next to `Project.toml` of the package.
"""
default_config_path()::String = joinpath(something(pkgdir(@__MODULE__), pwd()),
                                         "config.toml")

"""
    usage()::String

The command-line usage summary printed by `--help` and after a usage error.
"""
function usage()::String
    return """
           Usage: julia scripts/run.jl [OPTIONS] [CONFIG_FILE]

           Open one terminal tab or window per target listed in the TOML configuration.

           Options:
             -c, --config PATH    Configuration file (default: config.toml next to the project)
             -d, --dry-run        Print the emulator commands without writing or launching anything
             -h, --help           Show this message and exit
           """
end

"""
    parse_arguments(args; default_config=default_config_path())::CliOptions

Parse the command line of the driver. A bare argument is the configuration path. Throws
`ArgumentError` for an unrecognized option or `--config` without a path.
"""
function parse_arguments(args::AbstractVector{<:AbstractString};
                         default_config::AbstractString=default_config_path())::CliOptions
    config_path = String(default_config)
    dry_run = false
    index = 1
    while index <= length(args)
        arg = args[index]
        if arg in ("-h", "--help")
            return CliOptions(true, config_path, dry_run)
        elseif arg in ("-d", "--dry-run")
            dry_run = true
            index += 1
        elseif arg in ("-c", "--config")
            if index + 1 > length(args)
                throw(ArgumentError("$(arg) requires a path argument."))
            end
            config_path = String(args[index + 1])
            index += 2
        elseif startswith(arg, "-")
            throw(ArgumentError("unrecognized option '$(arg)'."))
        else
            config_path = String(arg)
            index += 1
        end
    end
    return CliOptions(false, config_path, dry_run)
end

"""
    run_driver(args, io::IO, err::IO)::Int

Body of [`main`](@ref) without the logger setup.
"""
function run_driver(args::AbstractVector{<:AbstractString}, io::IO, err::IO)::Int
    options = try
        parse_arguments(args)
    catch e
        e isa ArgumentError || rethrow()
        println(err, "Error: ", e.msg, "\n")
        print(err, usage())
        return 1
    end
    if options.help
        print(io, usage())
        return 0
    end

    if !isfile(options.config_path)
        println(err, "Error: configuration file not found at '$(options.config_path)'.")
        println(err, "Create one from the template: cp config.example.toml config.toml")
        return 1
    end

    config = try
        load_config(options.config_path)
    catch e
        e isa ArgumentError || rethrow()
        println(err, "Error: ", sprint(showerror, e))
        return 1
    end

    @info "Session configuration loaded" path=options.config_path targets=length(config.targets) mode=config.terminal.mode dry_run=options.dry_run
    for (index, target) in enumerate(config.targets)
        @info "Target" index host=target.host port=target.port user=target.user title=target.title
    end

    if options.dry_run
        println(io,
                "Emulator commands (dry run; '<runtime-dir>' stands for the runtime directory):")
        for cmd in plan_sessions(config)
            println(io, "  ", command_string(cmd))
        end
        return 0
    end

    processes = try
        launch_sessions(config)
    catch e
        e isa MissingBinaryError || rethrow()
        println(err, "Error: ", sprint(showerror, e))
        return 1
    end
    @info "Sessions dispatched" emulator_processes=length(processes)
    return 0
end

"""
    main(args::AbstractVector{<:AbstractString}=ARGS; io::IO=stdout, err::IO=stderr)::Int

Run the command-line driver (see [`usage`](@ref)) and return the exit status instead of
calling `exit`: 0 when the sessions were dispatched or the dry run printed, 1 on a
usage, configuration, or missing-binary error. The dry-run listing and the usage text go
to `io`; error messages and log records go to `err`. `scripts/run.jl` is a thin wrapper
around this function.

# Example
```julia
exit(main(["--dry-run", "config.toml"]))
```
"""
function main(args::AbstractVector{<:AbstractString}=ARGS; io::IO=stdout,
              err::IO=stderr)::Int
    return with_logger(ConsoleLogger(err)) do
        return run_driver(args, io, err)
    end
end
