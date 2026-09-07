const TOP_LEVEL_KEYS = ("globals", "terminal", "targets")
const GLOBALS_KEYS = ("connect_timeout", "strict_host_key_checking", "log_level")
const TERMINAL_KEYS = ("emulator", "mode", "hold", "launch_settle_timeout")
const TARGET_KEYS = ("host", "port", "user", "password", "title",
                     "strict_host_key_checking")

"""
    reject_unknown_keys(table::AbstractDict, allowed, context::AbstractString)

Throw `ArgumentError` if `table` contains a key that is not in `allowed`, so that
misspelled configuration keys fail fast instead of silently falling back to defaults.
"""
function reject_unknown_keys(table::AbstractDict, allowed, context::AbstractString)
    unknown = sort!([string(k) for k in keys(table) if !(string(k) in allowed)])
    if !isempty(unknown)
        throw(ArgumentError("Unknown key(s) in $(context): $(join(unknown, ", ")). Allowed keys: $(join(allowed, ", "))."))
    end
    return nothing
end

"""
    typed_value(table::AbstractDict, key::AbstractString, ::Type{T}, default, context) where {T}

Return `table[key]` if present, otherwise `default`, checking that the value is a `T`.
Throws `ArgumentError` naming `context.key` on a type mismatch.
"""
function typed_value(table::AbstractDict, key::AbstractString, ::Type{T}, default,
                     context::AbstractString) where {T}
    value = get(table, key, default)
    if !(value isa T)
        throw(ArgumentError("Configuration key '$(context).$(key)' must be of type $(T); received $(typeof(value))."))
    end
    return value
end

"""
    required_value(table::AbstractDict, key::AbstractString, ::Type{T}, context) where {T}

Return `table[key]` checked to be a `T`; throws `ArgumentError` if the key is absent.
"""
function required_value(table::AbstractDict, key::AbstractString, ::Type{T},
                        context::AbstractString) where {T}
    if !haskey(table, key)
        throw(ArgumentError("Configuration table $(context) is missing the mandatory key '$(key)'."))
    end
    return typed_value(table, key, T, nothing, context)
end

"""
    parse_config(dict::AbstractDict)::SessionConfig

Build and validate a [`SessionConfig`](@ref) from an in-memory dictionary with the
layout of `config.example.toml`. Unknown keys, missing mandatory keys, wrong value types,
and out-of-range values raise `ArgumentError` with the offending key named.
"""
function parse_config(dict::AbstractDict)::SessionConfig
    reject_unknown_keys(dict, TOP_LEVEL_KEYS, "the top-level table")

    globals_table = typed_value(dict, "globals", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(globals_table, GLOBALS_KEYS, "[globals]")
    globals = GlobalConfig(typed_value(globals_table, "connect_timeout", Integer, 10,
                                       "[globals]"),
                           typed_value(globals_table, "strict_host_key_checking",
                                       AbstractString, "accept-new", "[globals]"),
                           typed_value(globals_table, "log_level", AbstractString, "ERROR",
                                       "[globals]"))

    terminal_table = typed_value(dict, "terminal", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(terminal_table, TERMINAL_KEYS, "[terminal]")
    terminal = TerminalOptions(typed_value(terminal_table, "emulator", AbstractString,
                                           "konsole", "[terminal]"),
                               typed_value(terminal_table, "mode", AbstractString, "tabs",
                                           "[terminal]"),
                               typed_value(terminal_table, "hold", Bool, false,
                                           "[terminal]"),
                               typed_value(terminal_table, "launch_settle_timeout", Real,
                                           30, "[terminal]"))

    if !haskey(dict, "targets")
        throw(ArgumentError("Configuration is missing the mandatory [[targets]] array."))
    end
    targets_raw = dict["targets"]
    if !(targets_raw isa AbstractVector) || isempty(targets_raw)
        throw(ArgumentError("Configuration key 'targets' must be a non-empty array of [[targets]] tables."))
    end

    targets = Vector{SshTarget}(undef, length(targets_raw))
    for (index, entry) in enumerate(targets_raw)
        context = "[[targets]] #$(index)"
        if !(entry isa AbstractDict)
            throw(ArgumentError("$(context) is not a table."))
        end
        reject_unknown_keys(entry, TARGET_KEYS, context)
        targets[index] = SshTarget(required_value(entry, "host", AbstractString, context),
                                   required_value(entry, "port", Integer, context),
                                   required_value(entry, "user", AbstractString, context),
                                   required_value(entry, "password", AbstractString,
                                                  context),
                                   typed_value(entry, "title", AbstractString, "", context),
                                   typed_value(entry, "strict_host_key_checking",
                                               Union{Nothing, AbstractString}, nothing,
                                               context))
    end

    return SessionConfig(globals, terminal, targets)
end

"""
    load_config(path::AbstractString)::SessionConfig

Read a TOML configuration file and return the validated [`SessionConfig`](@ref).
Throws `ArgumentError` if the file is missing, is not valid TOML, or violates the
schema.

# Example
```julia
config = load_config("config.toml")
```
"""
function load_config(path::AbstractString)::SessionConfig
    if !isfile(path)
        throw(ArgumentError("Configuration file not found: $(path)"))
    end
    parsed = try
        TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("Configuration file '$(path)' is not valid TOML: $(sprint(showerror, err))"))
    end
    return parse_config(parsed)
end
