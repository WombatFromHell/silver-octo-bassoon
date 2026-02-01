#!/usr/bin/env bash
distrobox create "$@" --volume /nix:/nix --volume /etc/nix:/etc/nix --volume /var/nix:/var/nix
