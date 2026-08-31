"""
    load_config(filepath::AbstractString)::SessionConfig

Read and parse a TOML configuration file into a typed [`SessionConfig`](@ref).
Throws `ArgumentError` if the file does not exist or fails validation constraints.

# Examples
```julia
config = load_config("config.toml")
```
"""
function load_config(filepath::AbstractString)::SessionConfig
    if !isfile(filepath)
        throw(ArgumentError("Configuration file not found: $(filepath)"))
    end

    raw_dict = try
        TOML.parsefile(filepath)
    catch err
        throw(ArgumentError("Failed to parse TOML configuration from '$(filepath)': $(err)"))
    end

    return parse_config(raw_dict)
end

"""
    parse_config(dict::AbstractDict)::SessionConfig

Construct and validate a [`SessionConfig`](@ref) instance from an in-memory dictionary.
"""
function parse_config(dict::AbstractDict)::SessionConfig
    # Parse globals section
    globals_dict = get(dict, "globals", Dict{String, Any}())
    connect_timeout = get(globals_dict, "connect_timeout", 10)
    strict_host_key_checking = get(globals_dict, "strict_host_key_checking", "accept-new")
    log_level = get(globals_dict, "log_level", "ERROR")

    globals = GlobalConfig(connect_timeout, strict_host_key_checking, log_level)

    # Parse terminal section
    term_dict = get(dict, "terminal", Dict{String, Any}())
    emulator = get(term_dict, "emulator", "konsole")
    mode_raw = get(term_dict, "mode", "tabs")
    hold = get(term_dict, "hold", false)

    mode = Symbol(mode_raw)
    terminal = TerminalOptions(emulator, mode, hold)

    # Parse targets section
    if !haskey(dict, "targets")
        throw(ArgumentError("Configuration missing mandatory '[[targets]]' array."))
    end

    targets_raw = dict["targets"]
    if !(targets_raw isa AbstractVector) || isempty(targets_raw)
        throw(ArgumentError("Configuration 'targets' must be a non-empty list of target tables."))
    end

    parsed_targets = Vector{SshTarget}(undef, length(targets_raw))
    for (idx, target_entry) in enumerate(targets_raw)
        if !(target_entry isa AbstractDict)
            throw(ArgumentError("Target entry #$(idx) is not a valid table/dictionary."))
        end

        for required_key in ("host", "port", "user", "password")
            if !haskey(target_entry, required_key)
                throw(ArgumentError("Target #$(idx) missing mandatory key '$(required_key)'."))
            end
        end

        host = target_entry["host"]
        port = target_entry["port"]
        user = target_entry["user"]
        password = target_entry["password"]
        title = get(target_entry, "title", "")
        host_key_override = get(target_entry, "strict_host_key_checking", nothing)

        parsed_targets[idx] = SshTarget(host, port, user, password, title,
                                        host_key_override)
    end

    return SessionConfig(globals, terminal, parsed_targets)
end
