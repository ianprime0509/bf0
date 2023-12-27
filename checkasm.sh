#!/bin/sh

asm=$(mktemp)
trap "rm -f '$asm'" EXIT INT TERM
echo 'bits 64' >"$asm"
cat >>"$asm"

obj=$(mktemp)
trap "rm -f '$obj'" EXIT INT TERM
nasm -o "$obj" "$asm" || exit 1

ndisasm -b64 "$obj" || exit 1
