module HeaderREPLs

using REPL
using REPL.LineEdit, REPL.Terminals
using REPL.Terminals: TextTerminal
using REPL.Terminals: cmove_up, cmove_col, clear_line
using REPL.LineEdit: TextInterface, MIState, ModeState
using REPL.LineEdit: state
using REPL: Options, REPLBackendRef
using REPL: raw!

import REPL: outstream, specialdisplay, terminal, answer_color, input_color,
    reset, prepare_next, setup_interface, run_frontend
import REPL.LineEdit: init_state

export AbstractHeader, HeaderREPL
export print_header, clear_io, refresh_header, find_prompt, trigger_search_keymap, mode_termination_keymap, trigger_prefix_keymap

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
    cleared::Bool
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
        true,
    )

const msgs = []  # debugging

## Interface that must be provided by concrete types:
"""
    prompt, modesym = setup_prompt(repl::HeaderREPL{H}, hascolor::Bool)

Return `prompt::LineEdit.Prompt` and a mode symbol `modesym::Symbol` that will appear in the julia history file.
"""
setup_prompt(repl::HeaderREPL, hascolor::Bool) = error("Unimplemented")

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

"""
    print_header(io::IO, header::CustomHeader)

Print `header` to `io`.

While you have to define `print_header`, generally you should not call it directly.
If you need to display the header, call `refresh_header`.
"""
print_header(io::IO, header::AbstractHeader) = error("Unimplemented")
print_header(repl::HeaderREPL) = print_header(terminal(repl), repl.header)

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

## Utilities

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
trigger_search_keymap(p::LineEdit.HistoryPrompt) = Dict{Any,Any}(
    "^R"    => (s,o...)->(enter_search(s, p, true)),
    "^S"    => (s,o...)->(enter_search(s, p, false)),
)
trigger_search_keymap(repl::HeaderREPL) = trigger_search_keymap(find_prompt(repl.interface, LineEdit.HistoryPrompt))

"""
    keymap_dict = trigger_prefix_keymap(p::PrefixHistoryPrompt)
    keymap_dict = trigger_prefix_keymap(repl::HeaderREPL)

Sets up the arrow keys and "^P" and "^N" to trigger reverse and forward prefix-search, respectively.
"""
trigger_prefix_keymap(p::LineEdit.PrefixHistoryPrompt) = Dict{Any,Any}(
    "^P" => (s,o...)->(edit_move_up(s) || enter_prefix_search(s, p, true)),
    "^N" => (s,o...)->(edit_move_down(s) || enter_prefix_search(s, p, false)),
    # Up Arrow
    "\e[A" => (s,o...)->(edit_move_up(s) || enter_prefix_search(s, p, true)),
    # Down Arrow
    "\e[B" => (s,o...)->(edit_move_down(s) || enter_prefix_search(s, p, false)),
    )
trigger_prefix_keymap(repl::HeaderREPL) = trigger_prefix_keymap(find_prompt(repl.interface, LineEdit.PrefixHistoryPrompt))

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
            clear_io(s, repl)
            transition(s, default_prompt) do
                LineEdit.state(s, default_prompt).input_buffer = buf
            end
        else
            LineEdit.edit_backspace(s)
        end
    end,
    "^C" => function (s,o...)
        LineEdit.move_input_end(s)
        repl.cleared = true
        print(terminal(s), "^C\n\n")
        transition(s, default_prompt)
        transition(s, :reset)
        LineEdit.refresh_line(s)
    end)
end

## History-based mode switching

# The biggest problem is that `transition` isn't amenable to the kind of specialization
# that we need here. By specializing this on Prompt we get a chance to fix this.
# This is admittedly type-piracy, hopefully without major consequence.
function REPL.LineEdit.activate(p::Prompt, s::ModeState, termbuf, term::TextTerminal)
    REPL.LineEdit.activate(p.repl, s, termbuf, term)
end
function REPL.LineEdit.activate(repl::HeaderREPL, s::ModeState, termbuf, term::TextTerminal)
    s.ias = REPL.LineEdit.InputAreaState(0, 0)
    REPL.LineEdit.refresh_line(s, termbuf)
    refresh_header(repl, s, termbuf, term)
    nothing
end
function REPL.LineEdit.activate(::AbstractREPL, s::ModeState, termbuf, term::TextTerminal)
    s.ias = REPL.LineEdit.InputAreaState(0, 0)
    REPL.LineEdit.refresh_line(s, termbuf)
    nothing
end

function REPL.LineEdit.deactivate(p::Prompt, s::ModeState, termbuf, term::TextTerminal)
    REPL.LineEdit.deactivate(p.repl, s, termbuf, term)
end
function REPL.LineEdit.deactivate(repl::HeaderREPL, s::ModeState, termbuf, term::TextTerminal)
    clear_io(s, repl)
    return s
end
function REPL.LineEdit.deactivate(::AbstractREPL, s::ModeState, termbuf, term::TextTerminal)
    REPL.LineEdit.clear_input_area(termbuf, s)
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

prepare_next(repl::HeaderREPL) = println(terminal(repl))

function clear_io(s, repl::HeaderREPL)
    if !repl.cleared
        LineEdit.clear_input_area(s)
        clear_header_area(terminal(s), repl.header)
        repl.cleared = true
    end
end
clear_io(s::MIState, repl::HeaderREPL) = clear_io(state(s), repl)

function refresh_header(repl::HeaderREPL, s::MIState, termbuf, terminal::UnixTerminal)
    clear_io(s, repl)
    print_header(terminal, repl.header)
    LineEdit.refresh_multi_line(s)
    repl.cleared = false
end
function refresh_header(repl::HeaderREPL, state, termbuf, terminal::UnixTerminal)
    print_header(terminal, repl.header)
    LineEdit.refresh_multi_line(state)
    repl.cleared = false
end
function refresh_header(s, repl::HeaderREPL)
    clear_io(s, repl)
    print_header(terminal(s), repl.header)
    LineEdit.refresh_multi_line(s)
    repl.cleared = false
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
