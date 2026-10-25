#!/bin/zsh --no-rcs
# Physics Calc: Script Filter backend. argv[1] = query. Prints Alfred Script Filter JSON.
# Pure zsh + qalc, no jq/python. qalc settings are explicit so the user's own
# ~/.config/qalculate/qalc.cfg can never change results (-defaults ignores it,
# and the "save ..." settings stop qalc from writing it back).

export LC_ALL=en_US.UTF-8
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

# Find qalc: Homebrew (Apple silicon, Intel), then anything else on PATH.
qalc_bin=""
for cand in /opt/homebrew/bin/qalc /usr/local/bin/qalc ${commands[qalc]}; do
  [[ -n $cand && -x $cand ]] && { qalc_bin=$cand; break; }
done

json_esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//[$'\x01'-$'\x08'$'\x0b'$'\x0c'$'\x0e'-$'\x1f'$'\x7f']/}
  print -rn -- "$s"
}

# One non-actionable row.
emit_invalid() {
  print -r -- "{\"items\":[{\"title\":\"$(json_esc "$1")\",\"subtitle\":\"$(json_esc "$2")\",\"valid\":false}]}"
  exit 0
}

query=${1}
# Trim surrounding whitespace.
query=${query##[[:space:]]#}
query=${query%%[[:space:]]#}
# Backslash means truncating integer division in qalc (7\2 = 3). Treat it as
# plain division like "/" so a stray backslash never silently drops the remainder.
query=${query//\\//}
[[ -z $query ]] && emit_invalid "Physics Calc" "Type an expression. Try: 5 N * 2 m to J"

if [[ -z $qalc_bin ]]; then
  cmd="brew install libqalculate"
  print -r -- "{\"items\":[{\"title\":\"Qalculate not installed. ↩ to copy: $cmd\",\"subtitle\":\"Paste in Terminal, then try again. ⇧ previews qalculate.github.io\",\"arg\":\"$cmd\",\"valid\":true,\"text\":{\"copy\":\"$cmd\"},\"quicklookurl\":\"https://qalculate.github.io\"}]}"
  exit 0
fi

qargs=(
  -defaults -m 1500
  -s "save config no" -s "save mode no" -s "save definitions no"
  -s "upxrates 0"        # never prompt for / fetch exchange rates
  -s "color 0" -s "vspace off"
  -s "prefixes off"      # keep m^2, not mm^2; compound units still go to named SI units
  -s "precision 16"      # internal working precision
  -s "digits 10"         # displayed significant digits
  -s "angle deg"        # trig uses degrees: sin(90) = 1. Type "rad" for radians, e.g. sin(pi rad)
)

# The leading space keeps qalc from treating a query like "-h" as an option.
terse=$("$qalc_bin" "${qargs[@]}" -t " $query" 2>/dev/null </dev/null)
full=$("$qalc_bin" "${qargs[@]}" " $query" 2>&1 </dev/null)

# qalc may print a one-time "Please select interpretation..." prompt; drop it.
if [[ $full == *"Parsing mode: "* ]]; then
  full=${full#*Parsing mode: }
  full=${full#$'\n'}
fi

# Separate qalc diagnostics from the "expression = result" line.
msgs=()
exprlines=()
for line in "${(@f)full}"; do
  [[ -z ${line//[[:space:]]/} ]] && continue
  if [[ $line == (error|warning):* ]]; then
    msgs+=("$line")
  else
    exprlines+=("$line")
  fi
done
line_full=${(j: :)exprlines}
terse=${terse%%$'\n'*}

# Anything qalc flagged as a parse problem is not a trustworthy number.
for m in "${msgs[@]}"; do
  if [[ $m == error:* || $m == *(ignored|interpreted|"Division by zero")* ]]; then
    m=${m#error: }
    m=${m#warning: }
    emit_invalid "$m" "Physics Calc could not evaluate: $query"
  fi
done
[[ -z $terse || -z $line_full ]] && emit_invalid "No result" "Physics Calc could not evaluate: $query"

# ASCII hyphen-minus pastes cleanly into code, LaTeX and other calculators.
terse=${terse//−/-}
line_full=${line_full//−/-}

# solve() and friends return vectors separated by a double space; add commas.
if [[ $terse == \[*\] ]]; then
  terse=${terse//  /, }
  line_full=${line_full//  /, }
fi

subtitle=$line_full
# Harmless warnings (e.g. stale exchange rates) ride along in the subtitle.
(( ${#msgs} )) && subtitle="$line_full   ·   ${msgs[1]}"

t=$(json_esc "$terse")
s=$(json_esc "$subtitle")
f=$(json_esc "$line_full")

print -r -- "{\"items\":[{\"title\":\"$t\",\"subtitle\":\"$s\",\"arg\":\"$t\",\"valid\":true,\"text\":{\"copy\":\"$t\",\"largetype\":\"$t\"},\"mods\":{\"cmd\":{\"subtitle\":\"Paste into the front app\",\"arg\":\"$t\",\"valid\":true},\"alt\":{\"subtitle\":\"Copy expression = result\",\"arg\":\"$f\",\"valid\":true}}}]}"
