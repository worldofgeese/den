# shellcheck shell=bash
# Emacs vterm shell-side integration
# Only active when running inside vterm
if [[ "$INSIDE_EMACS" = 'vterm' ]]; then
    vterm_printf() {
        printf $'\e]%s\e\\' "$1"
    }

    vterm_prompt_end() {
        vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"
    }
    PS1=$PS1'\[$(vterm_prompt_end)\]'

    vterm_cmd() {
        local vterm_elisp=""
        while [ $# -gt 0 ]; do
            vterm_elisp="$vterm_elisp\"$(printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')\" "
            shift
        done
        vterm_printf "51;E$vterm_elisp"
    }

    find-file() {
        vterm_cmd find-file "$(realpath "${@:-.}")"
    }

    vterm-clear-scrollback() {
        vterm_printf "51;Evterm-clear-scrollback"
        clear
    }
fi
