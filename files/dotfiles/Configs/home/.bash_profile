# ~/.bash_profile: executed by bash for login shells.

# export GOPATH="$HOME/.local/share/go"
# export GOMODCACHE="$GOPATH/pkg/mod"
# export GOBIN="$GOPATH/bin"
# if [ -d "$GOBIN" ]; then
#   export PATH="$PATH:$GOBIN"
# fi

if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
fi
# Source ~/.bashrc if it exists
if [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
