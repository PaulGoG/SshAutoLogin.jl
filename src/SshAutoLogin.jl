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
       build_single_window_command,
       generate_tabs_file_content,
       build_tabs_launch_command,
       launch_all_sessions

end # module SshAutoLogin
