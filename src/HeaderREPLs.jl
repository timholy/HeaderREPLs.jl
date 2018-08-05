module HeaderREPLs

using REPL
using REPL.LineEdit, REPL.Terminals

using REPL.Terminals: TextTerminal
using REPL.Terminals: cmove_up, cmove_col, clear_line

using REPL.LineEdit: TextInterface, ModalInterface, Prompt, HistoryPrompt, PrefixHistoryPrompt  # modes
using REPL.LineEdit: ModeState,     MIState,     PromptState, SearchState, PrefixSearchState    # states
using REPL.LineEdit: InputAreaState
using REPL.LineEdit: state, mode

using REPL: Options, REPLBackendRef
using REPL: raw!

# Internal customizations
import REPL: outstream, specialdisplay, terminal, answer_color, input_color,
    reset, prepare_next, setup_interface, run_frontend
import REPL.LineEdit: init_state

# Required user customization API
export AbstractHeader, HeaderREPL
export print_header, nlines, append_keymaps!
# alternatively `clear_header_area`, but this doesn't seem to need to be exported
# Convenience utilities
export trigger_search_keymap, mode_termination_keymap, trigger_prefix_keymap
export find_prompt, clear_io, refresh_header

abstract type AbstractHeader end

mutable struct HeaderREPL{H<:AbstractHeader} <: AbstractREPL
    t::TextTerminal
    header::H
    hascolor::Bool
    prompt_color::String
    input_color::String
    answer_color::String
    history_file::Bool
    envcolors::Bool
    waserror::Bool
    specialdisplay::Union{Nothing,AbstractDisplay}
    options::Options
    mistate::Union{MIState,Nothing}
    interface::ModalInterface
    backendref::REPLBackendRef
    clearheader::Bool  # next time we transition should we erase the space for the header?
end

## HeaderREPL is meant to integrate with LineEditREPL
HeaderREPL(main_repl::LineEditREPL, header::H) where H =
    HeaderREPL{H}(
        terminal(main_repl),
        header,
        main_repl.hascolor,
        main_repl.prompt_color,
        main_repl.input_color,
        main_repl.answer_color,
        main_repl.history_file,
        main_repl.envcolors,
        main_repl.waserror,
        main_repl.specialdisplay,
        main_repl.options,
        main_repl.mistate,
        main_repl.interface,
        main_repl.backendref,
        true
    )

const msgs = []  # debugging

### Interface that must be provided in terms of application-dependent concrete types ###

"""
    prompt, modesym = setup_prompt(repl::HeaderREPL{H}, hascolor::Bool)

Return `prompt::LineEdit.Prompt` and a mode symbol `modesym::Symbol` that will appear in the julia history file.
"""
setup_prompt(repl::HeaderREPL, hascolor::Bool) = error("Unimplemented")

"""
    print_header(io::IO, header::CustomHeader)

Print `header` to `io`.

While you have to define `print_header`, generally you should not call it directly.
If you need to display the header, call `refresh_header`.
"""
print_header(io::IO, header::AbstractHeader) = error("Unimplemented")
print_header(repl::HeaderREPL) = print_header(terminal(repl), repl.header)

"""
    append_keymaps!(keymaps, repl::HeaderREPL{H})

Append `Dict{Any,Any}` key maps to `keymaps` in order of highest priority first.
Some typically useful keymaps (in conventional order of priority):

- [`trigger_search_keymap`](@ref)
- [`mode_termination_keymap`](@ref)
- [`trigger_prefix_keymap`](@ref)
- `REPL.LineEdit.history_keymap`
- `REPL.LineEdit.default_keymap`
- `REPL.LineEdit.escape_defaults`
"""
append_keymaps!(keymaps, repl::HeaderREPL) = error("Unimplemented")

# A header can provide either `nlines` or directly implement `clear_header_area`
"""
    n = nlines(terminal, header::AbstractHeader)

Return the number of terminal lines required for display of `header` on `terminal`.
    """
nlines(terminal, header::AbstractHeader) = error("Unimplemented")
nlines(repl::HeaderREPL) = nlines(terminal(repl), repl.header)

"""
    clear_header_area(terminal, header::AbstractHeader)

Move to the top of the area used for display of `header`, clearing lines
as you go.

In most cases you can probably just implement [`nlines`](@ref) instead.
"""
function clear_header_area(terminal, header::AbstractHeader)
    cmove_col(terminal, 1)
    clear_line(terminal)
    for i = 1:nlines(terminal, header)
        cmove_up(terminal)
        clear_line(terminal)
    end
    nothing
end
clear_header_area(repl::HeaderREPL) = clear_header_area(terminal(repl), repl.header)


### Utilities ###

"""
    find_prompt(mi, "julia")
    find_prompt(mi, PrefixHistoryPrompt)

Return the selected prompt from `mi`, searching either for the prompt-string
of a `Prompt` or, for other `TextInterface`s, searching by type.
"""
function find_prompt(interface::ModalInterface, promptstr::AbstractString)
    for p in interface.modes
        if isa(p, Prompt) && isa(p.prompt, AbstractString)
            if startswith(p.prompt, promptstr)
                return p
            end
        end
    end
    return nothing
end
function find_prompt(interface::ModalInterface, ::Type{P}) where P<:TextInterface
    for p in interface.modes
        isa(p, P) && return p
    end
    return nothing
end
find_prompt(s, p) = find_prompt(s.interface, p)

"""
    keymap_dict = trigger_search_keymap(p::HistoryPrompt)
    keymap_dict = trigger_search_keymap(repl::HeaderREPL)

Sets up "^R" and "^S" to trigger reverse and forward search, respectively.
"""
trigger_search_keymap(p::HistoryPrompt) = Dict{Any,Any}(
    "^R"    => (s,o...)->(LineEdit.enter_search(s, p, true)),
    "^S"    => (s,o...)->(LineEdit.enter_search(s, p, false)),
)
trigger_search_keymap(repl::HeaderREPL) = trigger_search_keymap(find_prompt(repl.interface, HistoryPrompt))

"""
    keymap_dict = trigger_prefix_keymap(p::PrefixHistoryPrompt)
    keymap_dict = trigger_prefix_keymap(repl::HeaderREPL)

Sets up the arrow keys and "^P" and "^N" to trigger reverse and forward prefix-search, respectively.
"""
trigger_prefix_keymap(p::PrefixHistoryPrompt) = Dict{Any,Any}(
    "^P" => (s,o...)->(LineEdit.edit_move_up(s) || LineEdit.enter_prefix_search(s, p, true)),
    "^N" => (s,o...)->(LineEdit.edit_move_down(s) || LineEdit.enter_prefix_search(s, p, false)),
    # Up Arrow
    "\e[A" => (s,o...)->(LineEdit.edit_move_up(s) || LineEdit.enter_prefix_search(s, p, true)),
    # Down Arrow
    "\e[B" => (s,o...)->(LineEdit.edit_move_down(s) || LineEdit.enter_prefix_search(s, p, false)),
    )
trigger_prefix_keymap(repl::HeaderREPL) = trigger_prefix_keymap(find_prompt(repl.interface, PrefixHistoryPrompt))

"""
    keymap_dict = mode_termination_keymap(repl::HeaderREPL, default_prompt::Prompt)

Default back to `default_prompt` for "^C" and hitting backspace as the first character of the line.
"""
function mode_termination_keymap(repl::HeaderREPL, default_prompt::Prompt; copybuffer::Bool=true)
    Dict{Any,Any}(
    '\b' => function (s,o...)
        if isempty(s) || position(LineEdit.buffer(s)) == 0
            copybuffer || LineEdit.edit_clear(s)
            buf = copy(LineEdit.buffer(s))
            transition(s, default_prompt) do
                LineEdit.state(s, default_prompt).input_buffer = buf
            end
        else
            LineEdit.edit_backspace(s)
        end
    end,
    "^C" => function (s,o...)
        LineEdit.move_input_end(s)
        print(terminal(s), "^C\n\n")
        repl.clearheader = false
        transition(s, default_prompt)
        repl.clearheader = true
        transition(s, :reset)
        LineEdit.refresh_line(s)
    end)
end

"""
    clear_io(s, repl)

Erases both the input line and the header.
"""
function clear_io(s, repl::HeaderREPL)
    LineEdit.clear_input_area(s)
    clear_header_area(terminal(s), repl.header)
end
clear_io(s::MIState, repl::HeaderREPL) = clear_io(state(s), repl)

"""
    refresh_header(s, repl; clearheader=true)
    refresh_header(repl, s, termbuf, terminal; clearheader=true)

Clear (if `clearheader` is true) and redraw the header and input line.
"""
function refresh_header(repl::HeaderREPL, s::MIState, termbuf, terminal::UnixTerminal; clearheader=true)
    clearheader && repl.clearheader && clear_io(s, repl)
    print_header(terminal, repl.header)
    repl.clearheader = true
    LineEdit.refresh_multi_line(s)
end
function refresh_header(repl::HeaderREPL, state, termbuf, terminal::UnixTerminal)
    error("why am I here and why don't I clear_io?")
    print_header(terminal, repl.header)
    repl.clearheader = true
    LineEdit.refresh_multi_line(state)
end
function refresh_header(s, repl::HeaderREPL; clearheader=true)
    clearheader && repl.clearheader && clear_io(s, repl)
    print_header(terminal(s), repl.header)
    repl.clearheader = true
    LineEdit.refresh_multi_line(s)
end

### Internals ###

## History-based mode switching

# I tried but failed to extend it via the `activate` and `deactive` calls, but it proved
# challenging due to the fact that `activate` and `deactivate` only get information about
# one of the two states, and this seems to need to know both the "source" and "destination"
# modes. The most problematic case was history-search, which switches transiently into a
# "real" prompt and then back into a ("parented") search mode which, unlike "real" modes,
# should not (yet) clear the header.

# So this takes the drastic strategy of overwriting several REPL methods.
# This triggers warnings when you load the package.
# TODO?: get some kind of cleaned-up implementation into REPL itself.

moderepl(p::Prompt)              = p.repl
moderepl(p::HistoryPrompt)       = nothing
moderepl(p::PrefixHistoryPrompt) = moderepl(p.parent_prompt)
moderepl(s::MIState)             = moderepl(mode(s))
moderepl(s::PromptState)         = moderepl(s.p)
moderepl(s::SearchState)         = moderepl(s.parent)   # should this return nothing? here `mode` is @assert false
moderepl(s::PrefixSearchState)   = moderepl(s.parent)

function LineEdit.transition(f::Function, s::PrefixSearchState, mode)
    if isdefined(s, :mi)
        _transition((args...)->nothing, s.mi, mode; aflag=true, dflag=isa(moderepl(s), HeaderREPL))
    end
    s.parent = mode
    s.histprompt.parent_prompt = mode
    if isdefined(s, :mi)
        _transition(f, s.mi, s.histprompt; aflag=false, dflag=false)
    else
        f()
    end
    nothing
end

function _transition(f::Function, s::MIState, newmode; aflag::Bool=true, dflag::Bool=true)
    LineEdit.cancel_beep(s)
    if newmode === :abort
        s.aborted = true
        return
    end
    if newmode === :reset
        LineEdit.reset_state(s)
        return
    end
    if !haskey(s.mode_state, newmode)
        s.mode_state[newmode] = init_state(terminal(s), newmode)
    end
    termbuf = TerminalBuffer(IOBuffer())
    t = terminal(s)
    # @show aflag dflag
    # prettyprint(mode(s))
    # print(" => ")
    # prettyprint(newmode)
    # println()
    # sleep(2.0)
    s.mode_state[mode(s)] = if dflag
        LineEdit.deactivate(mode(s), state(s), termbuf, t)
    else
        _deactivate(mode(s), state(s), termbuf, t)
    end
    s.current_mode = newmode
    f()
    if aflag
        LineEdit.activate(newmode, state(s, newmode), termbuf, t)
    else
        _activate(newmode, state(s, newmode), termbuf, t)
    end
    LineEdit.commit_changes(t, termbuf)
    nothing
end

prettyprint(p::Prompt) = print(p)
prettyprint(::T) where T = print(T)

function REPL.LineEdit.activate(p::TextInterface, s::ModeState, termbuf, term::TextTerminal)
    repl = moderepl(p)
    if repl isa HeaderREPL
        # println("activate"); sleep(0.5)
        print_header(term, repl.header)
    end
    _activate(p, s, termbuf, term)
end
function _activate(p, s, termbuf, term)
    s.ias = InputAreaState(0, 0)
    LineEdit.refresh_line(s, termbuf)
    nothing
end

function REPL.LineEdit.deactivate(p::TextInterface, s::ModeState, termbuf, term::TextTerminal)
    repl = moderepl(p)
    # @show typeof(repl)
    # repl isa HeaderREPL && @show repl.clearheader
    # sleep(0.5)
    if repl isa HeaderREPL && repl.clearheader
        # println("deactivate"); sleep(0.5)
        clear_io(s, repl)
        return s
    end
    _deactivate(p, s, termbuf, term)
end
function _deactivate(p, s, termbuf, term)
    LineEdit.clear_input_area(termbuf, s)
    return s
end

## Generic implementations

outstream(r::HeaderREPL) = r.t
specialdisplay(r::HeaderREPL) = r.specialdisplay
terminal(r::HeaderREPL) = r.t

answer_color(r::HeaderREPL) = r.envcolors ? Base.answer_color() : r.answer_color
input_color(r::HeaderREPL) = r.envcolors ? Base.input_color() : r.input_color

function reset(repl::HeaderREPL)
    raw!(repl.t, false)
    print(repl.t, Base.text_colors[:normal])
end

function prepare_next(repl::HeaderREPL)
    println(terminal(repl))
end

function respond(f, repl::HeaderREPL, main; pass_empty = false)  # this does *not* extend REPL.respond
    dorespond = REPL.respond(f, repl, main; pass_empty=pass_empty)
    return function _dorespond(s, buf, ok)
        # println("clearheader = false"); sleep(0.5)
        repl.clearheader = false
        ret = dorespond(s, buf, ok)
        repl.clearheader = true
        return ret
    end
end

init_state(header::AbstractHeader, terminal, prompt) = init_state(terminal, prompt)

setup_interface(
    repl::HeaderREPL;
    hascolor::Bool = repl.options.hascolor,
    extra_repl_keymap::Union{Dict,Vector{<:Dict}} = repl.options.extra_keymap
) = setup_interface(repl, hascolor, extra_repl_keymap)

function setup_interface(
    repl::HeaderREPL,
    hascolor::Bool,
    extra_repl_keymap::Union{Dict,Vector{<:Dict}},
)
    ## Set up the prompt
    prompt, modesym = setup_prompt(repl, hascolor)
    prompt.repl = repl

    ## Set history provider
    julia_prompt = find_prompt(repl.interface, "julia")
    if repl.history_file
        if julia_prompt !== nothing
            prompt.hist = julia_prompt.hist
            prompt.hist.mode_mapping[modesym] = prompt
        end
    end

    ## Set up the keymap
    # Canonicalize user keymap input
    if isa(extra_repl_keymap, Dict)
        extra_repl_keymap = [extra_repl_keymap]
    end
    prompt.keymap_dict = LineEdit.keymap(append_keymaps!(extra_repl_keymap, repl))

    push!(repl.interface.modes, prompt)
    repl.mistate.mode_state[prompt] = init_state(repl.header, terminal(repl), prompt)

    return repl.interface
end

# You typically shouldn't call this, since it's already running via the standard REPL
run_frontend(repl::HeaderREPL, backend::REPLBackendRef) = nothing

end # module
