#!/usr/bin/env sh
# Flags a commit message that reads as generated prose rather than the terse
# notes an engineer writes.
#
# The body of a commit is meant to be short imperative bullets that say what
# changed and why. Multi-sentence explanatory paragraphs and marketing wording
# are the tell of a message written to impress rather than to inform, and they
# make the history read as machine-produced. This catches both before they land.
#
# Usage: message-tone.sh <path-to-message-file>
# Exit:  0 clean, 1 a problem was found (details on stderr).

set -eu

# Byte comparisons, so character classes below do not shift with the locale.
LC_ALL=C
export LC_ALL

file=$1

# Drop git's comment lines and everything from the scissors line down; only the
# authored message is judged.
body=$(sed '/^# ------------------------ >8/,$d' "$file" | grep -v '^#' || true)

# The body proper: everything after the subject and its blank line.
rest=$(printf '%s\n' "$body" | sed -n '3,$p')

status=0

# A body line that starts at the margin with a capital letter and is not a
# bullet is a prose sentence. Bullets start with a marker, wrapped continuations
# and nested lines are indented, and imperative bullets start lowercase, so a
# capitalised margin line is the paragraph style we are rejecting.
printf '%s\n' "$rest" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        -* | '*'* | +* | ' '* | [0-9]*) continue ;;
    esac
    case "$(printf '%s' "$line" | cut -c1)" in
        [ABCDEFGHIJKLMNOPQRSTUVWXYZ])
            printf 'message-tone: body reads as prose; use "-" bullets, not sentences:\n  %s\n' "$line" >&2
            exit 1
            ;;
    esac
done || status=1

# Wording that reads as marketing or as a model padding for length. The list is
# deliberately small and distinctive to avoid catching ordinary engineering
# words.
filler='seamlessl|effortlessl|robustl|leverag|furthermore|moreover|comprehensive|cutting-edge|state-of-the-art|delve|utiliz|plethora|myriad|unleash|elevate the|powerful new'
if printf '%s\n' "$body" | grep -qEi "$filler"; then
    printf 'message-tone: marketing or padded wording:\n' >&2
    printf '%s\n' "$body" | grep -nEi "$filler" >&2
    status=1
fi

# A body line far past a normal wrap is a wall of text rather than a note.
long=$(printf '%s\n' "$rest" | awk 'length > 100 { print "  " $0 }')
if [ -n "$long" ]; then
    printf 'message-tone: wrap body lines nearer 72 characters:\n%s\n' "$long" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    printf '\nRewrite the message as terse imperative bullets and commit again.\n' >&2
fi

exit "$status"
