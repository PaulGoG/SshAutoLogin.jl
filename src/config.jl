const TOP_LEVEL_KEYS = ("globals", "terminal", "targets")
const GLOBALS_KEYS = ("connect_timeout", "strict_host_key_checking", "log_level")
const TERMINAL_KEYS = ("mode", "hold", "launch_settle_timeout")
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
A boolean is never accepted for a numeric `T`, although `Bool <: Integer` in Julia, so
that `port = true` cannot silently become port 1. Throws `ArgumentError` naming
`context.key` on a type mismatch.
"""
function typed_value(table::AbstractDict, key::AbstractString, ::Type{T}, default,
                     context::AbstractString) where {T}
    value = get(table, key, default)
    if !(value isa T) || (value isa Bool && T !== Bool)
        location = isempty(context) ? key : "$(context).$(key)"
        throw(ArgumentError("Configuration key '$(location)' must be of type $(T); received $(typeof(value))."))
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
    global_defaults = GlobalConfig()
    globals = GlobalConfig(typed_value(globals_table, "connect_timeout", Integer,
                                       global_defaults.connect_timeout, "[globals]"),
                           typed_value(globals_table, "strict_host_key_checking",
                                       AbstractString,
                                       global_defaults.strict_host_key_checking,
                                       "[globals]"),
                           typed_value(globals_table, "log_level", AbstractString,
                                       global_defaults.log_level, "[globals]"))

    terminal_table = typed_value(dict, "terminal", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(terminal_table, TERMINAL_KEYS, "[terminal]")
    terminal_defaults = TerminalOptions()
    terminal = TerminalOptions(typed_value(terminal_table, "mode", AbstractString,
                                           String(terminal_defaults.mode), "[terminal]"),
                               typed_value(terminal_table, "hold", Bool,
                                           terminal_defaults.hold, "[terminal]"),
                               typed_value(terminal_table, "launch_settle_timeout", Real,
                                           terminal_defaults.launch_settle_timeout,
                                           "[terminal]"))

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
    syntax_error_line(err::TOML.ParserError)::Int

Number of the line that `showerror` would print for `err`: the line that holds the
position of the error in the source text. The `line` field of the parser is not used,
because it is ahead by one whenever the last character read was a newline. It is the
fallback, with 0, when the parser kept no source text.
"""
function syntax_error_line(err::TOML.ParserError)::Int
    text = err.str
    position = err.pos
    (text === nothing || position === nothing) && return something(err.line, 0)
    before = prevind(text, clamp(position, 1, ncodeunits(text) + 1))
    return count(==('\n'), SubString(text, 1, before)) + 1
end

"""
    load_config(path::AbstractString)::SessionConfig

Read a TOML configuration file and return the validated [`SessionConfig`](@ref).
Throws `ArgumentError` if the file is missing, grants any permission to group or others
(it holds passwords; use mode 600), cannot be read, is not valid TOML, or violates the
schema. A syntax error is reported by its kind and line number only: the offending line
may be the password line and is never printed.

# Example
```julia
config = load_config("config.toml")
```
"""
function load_config(path::AbstractString)::SessionConfig
    if !isfile(path)
        throw(ArgumentError("Configuration file not found: $(path)"))
    end
    mode = filemode(path) & 0o777
    if mode & 0o077 != 0
        throw(ArgumentError("Configuration file '$(path)' is accessible to group or others (mode $(string(mode; base=8, pad=3))). It holds passwords; set it to mode 600: chmod 600 '$(path)'"))
    end
    # tryparsefile returns a syntax error instead of throwing it. An ArgumentError thrown
    # from a catch block would keep the ParserError as its cause, and the display of an
    # uncaught error prints every cause, the offending source line included.
    parsed = try
        TOML.tryparsefile(path)
    catch err
        err isa SystemError || rethrow()
        throw(ArgumentError("Configuration file '$(path)' cannot be read: $(Libc.strerror(err.errnum))."))
    end
    if parsed isa TOML.ParserError
        throw(ArgumentError("Configuration file '$(path)' is not valid TOML: $(parsed.type) near line $(syntax_error_line(parsed)). The line is not printed because it may hold a password."))
    end
    return parse_config(parsed)
end
