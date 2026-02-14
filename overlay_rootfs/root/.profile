#!/bin/sh

if [ "$PS1" ]; then
	if [ "`id -u`" -eq 0 ]; then
		export PS1='[\u@\h:\W]# '
	else
		export PS1='[\u@\h:\W]$ '
	fi
fi
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
alias ls="ls -F --color=auto"
alias la="ls -A"
alias ll="ls -l"
alias cp="cp -i"
alias mv="mv -i"
alias rm="rm -i"

umask 022
