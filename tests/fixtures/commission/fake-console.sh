#!/bin/bash
# fake-console.sh LOG SCREENS: a console for the expect script of
# console_script, run by expect in place of pct console. It gives the login
# prompt, a shell prompt, and on keel-init the screens of the file SCREENS,
# one per line: "menu TITLE" draws a menu and logs the key that chose it,
# "box TITLE" draws a box with that title that reads no key (the output of
# a command, as keel-init shows it). Then the shell prompt again. A test
# helper: not shipped.
log=$1 screens=$2
stty -echo
read -r _          # the Enter that wakes tty1
printf 'kc login: '
read -r _
printf 'Password: '
read -r _
printf '\nroot@kc:~# '
read -r _          # keel-init
while read -r kind title <&3; do
    case $kind in
        menu)
            printf '\n== %s ==\n  Primary\n  Replica\n  Cloud simple\n' "$title"
            IFS= read -rsn1 key
            printf '%s\t%s\n' "$title" "$key" >> "$log"
            printf '\n  [%s]\n' "$key"
            IFS= read -rsn1 _ ;;
        box)
            printf '\n== %s ==\n  $ keel spec apply\n  done\n' "$title"
            sleep 1 ;;
    esac
done 3< "$screens"
printf '\nroot@kc:~# '
read -r _
