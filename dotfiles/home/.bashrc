export PATH="$PATH:$HOME/.local/bin:$HOME/.local/bin/scripts:$HOME/.local/share/nvim/mason/bin:/usr/local/bin:$HOME/.rd/bin"

if [[ $- == *i* ]]; then
  # only if interactive
  if command -v fish &>/dev/null && [[ $(ps -o comm= -p $PPID) != "fish" ]]; then
    fish -l
    exit 0
  fi
fi
