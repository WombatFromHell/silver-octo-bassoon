#!/bin/bash

FONT_LIST="JetBrainsMono AnonymousPro CascadiaCode CascadiaMono FiraCode FiraMono Meslo"
OUTPUT_DIR="$HOME/.local/share/fonts/nerd/"
BASE_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.1.1/"

mkdir -p ./nerd
mkdir -p ${OUTPUT_DIR}

echo "Unpacking selected fonts: ${FONT_LIST}"

for i in ${FONT_LIST}; do
  FILE="${i}.tar.xz"
  URL="${BASE_URL}${FILE}"
  if ! [ -r "${FILE}" ]; then
    echo "Grabbing ${i} from: ${URL}"
    curl -OL ${URL}
  fi
  if [ -r "${FILE}" ]; then
    echo "Unpacking ${FILE}"
    tar -xvf ${FILE} -C ./nerd/
  fi
done

rsync -rvh ./nerd/ ${OUTPUT_DIR}
fc-cache -f
echo "Installed latest patched nerd fonts to: ${OUTPUT_DIR}"
