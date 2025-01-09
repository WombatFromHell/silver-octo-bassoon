export PATH="$PATH:$HOME/.local/bin"

if [[ $- == *i* ]]; then
  # only if interactive
  if command -v fish &>/dev/null && [[ $(ps -o comm= -p $PPID) != "fish" ]]; then
    fish -l
    exit 0
  fi
fi
