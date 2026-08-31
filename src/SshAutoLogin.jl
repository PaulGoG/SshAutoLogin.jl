module SshAutoLogin

using TOML: TOML

include("validation.jl")
include("types.jl")
include("config.jl")
include("process.jl")

export SshTarget,
       GlobalConfig,
       TerminalOptions,
       SessionConfig,
       load_config,
       parse_config,
       validate_target_fields,
       validate_global_fields,
       validate_terminal_fields,
       build_terminal_command,
       launch_session,
       launch_all_sessions

end # module SshAutoLogin
