#!/opt/homebrew/bin/bash
# A viewer that dies: echoes the first two log lines and exits 3 (18: the hook's fallback must carry the rest).
IFS= read -r a && echo "$a"; IFS= read -r b && echo "$b"; exit 3
