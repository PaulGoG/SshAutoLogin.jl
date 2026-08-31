const VALID_HOST_KEY_POLICIES = Set(["accept-new", "yes", "no"])
const VALID_LOG_LEVELS = Set(["QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG",
                              "DEBUG1", "DEBUG2", "DEBUG3"])
const VALID_TERMINAL_MODES = Set([:tabs, :windows])
const VALID_TERMINAL_EMULATORS = Set(["konsole"])

"""
    validate_target_fields(host, port, user, password, host_key_policy)

Validate target fields against operational constraints. Throws `ArgumentError` on breach.
"""
function validate_target_fields(host::AbstractString,
                                port::Integer,
                                user::AbstractString,
                                password::AbstractString,
                                host_key_policy::Union{Nothing, AbstractString})
    if isempty(strip(host))
        throw(ArgumentError("SSH target 'host' cannot be empty or whitespace."))
    end
    if occursin(r"\s", host)
        throw(ArgumentError("SSH target 'host' ('$(host)') cannot contain whitespace."))
    end
    if !(1 <= port <= 65535)
        throw(ArgumentError("SSH target 'port' ($(port)) out of range [1, 65535]."))
    end
    if isempty(strip(user))
        throw(ArgumentError("SSH target 'user' cannot be empty or whitespace."))
    end
    if occursin(r"\s", user)
        throw(ArgumentError("SSH target 'user' ('$(user)') cannot contain whitespace."))
    end
    if isempty(password)
        throw(ArgumentError("SSH target 'password' for $(user)@$(host) cannot be empty."))
    end
    if host_key_policy !== nothing && !(host_key_policy in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Invalid target-specific 'strict_host_key_checking': '$(host_key_policy)'. Allowed: $(collect(VALID_HOST_KEY_POLICIES))."))
    end
    return nothing
end

"""
    validate_global_fields(connect_timeout, host_key_policy, log_level)

Validate global SSH parameters. Throws `ArgumentError` on breach.
"""
function validate_global_fields(connect_timeout::Integer,
                                host_key_policy::AbstractString,
                                log_level::AbstractString)
    if connect_timeout <= 0
        throw(ArgumentError("Global 'connect_timeout' ($(connect_timeout)) must be positive integer (> 0)."))
    end
    if !(host_key_policy in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Invalid global 'strict_host_key_checking': '$(host_key_policy)'. Allowed: $(collect(VALID_HOST_KEY_POLICIES))."))
    end
    if !(uppercase(log_level) in VALID_LOG_LEVELS)
        throw(ArgumentError("Invalid global 'log_level': '$(log_level)'. Allowed: $(collect(VALID_LOG_LEVELS))."))
    end
    return nothing
end

"""
    validate_terminal_fields(emulator, mode)

Validate terminal emulator configuration. Throws `ArgumentError` on breach.
"""
function validate_terminal_fields(emulator::AbstractString, mode::Symbol)
    if !(lowercase(emulator) in VALID_TERMINAL_EMULATORS)
        throw(ArgumentError("Unsupported terminal 'emulator': '$(emulator)'. Currently supported: $(collect(VALID_TERMINAL_EMULATORS))."))
    end
    if !(mode in VALID_TERMINAL_MODES)
        throw(ArgumentError("Invalid terminal 'mode': :$(mode). Allowed: $(collect(VALID_TERMINAL_MODES))."))
    end
    return nothing
end
