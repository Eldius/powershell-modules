@{
    # Darcula: double-line prompt in the JetBrains Darcula palette.
    # Colors are SGR parameters (no ESC prefix); 38;5;N picks xterm-256 color N,
    # approximating Darcula colors meant for a #2B2B2B background.
    Layout     = 'Double'
    PromptChar = '❯'

    Clean      = '✔'
    Dirty      = '✘'
    Staged     = '●'
    Unstaged   = '○'
    Untracked  = '?'
    Conflicted = '!'
    Ahead      = '↑'
    Behind     = '↓'

    ColorUserHost = '38;5;103'  # purple  ~#9876AA
    ColorAdmin    = '38;5;203'  # red     ~#FF6B68
    ColorPath     = '38;5;67'   # blue    ~#6897BB
    ColorBranch   = '38;5;173'  # orange  ~#CC7832
    ColorClean    = '38;5;143'  # green   ~#A5C261
    ColorDirty    = '38;5;221'  # yellow  ~#FFC66D
    ColorStatus   = '38;5;146'  # fg gray ~#A9B7C6
    ColorError    = '38;5;203'  # red     ~#FF6B68
    ColorPrompt   = '38;5;173'  # orange  ~#CC7832
}
