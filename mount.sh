#!/bin/sh

## Load libraries
scriptDir=$(dirname "$BASH_SOURCE")
source "$scriptDir/com.cyberinternauts.linux.libraries/baselib.sh"
source "$scriptDir/mountlib.sh"

## Switch to script directory
switchToScriptDirectory

## Accepted concurrent tasks
if [ "$1" == "--is-mounted" ]; then
	ensureMount "$2"
	exit $?
fi

if [ "$1" = "--off-loop-cfg" ]; then
	configName="$2"
	
	while [ "" = "" ];
	do
		sleep 900
	done
	exit
fi


## Ensure launched only once
launchOnlyOnce


if [ "$1" = "--bind-folder" ]; then
	bindFolder "$2" "$3"
	exit $?
elif [ "$1" = "--unbind-folder" ]; then
	unbindFolder "$2"
	exit $?
elif [ "$1" = "--turn-off-bind-folder" ]; then
	turnOffBinding "$2"
	exit $?
elif [ "$1" = "--turn-on-bind-folder" ]; then
	turnOnBinding "$2"
	exit $?
else
	mountConfigs
fi
