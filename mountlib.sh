mountLibConfigFolder=".mount.cfg/"
mountLibDefaultConfigFile="$mountLibConfigFolder""default.cfg"

function unbindFolder()
#$1 path folder path containing mounted point subfolders
{
	local path="$1"	
	if [ "$path" = "" ]; then
		echo "Missing first parameter \$path" >&2
		return 1
	fi
	if [ ! -d "$path" ]; then
		echo "\$path \"$path\" is not a folder" >&2
		return 2
	fi
	
	#For each subfolders try to unmount
	local exitCode=0
	for d in "$path"/*/; do
		local isMounted=$(ensureMount "$d")
		if [ "$isMounted" = "Y" ]; then
			local realPath=$(getRealPath "$d")
			umount -l "$realPath" 2>/dev/null
			if [ $? -ne 0 ]; then exitCode=$?; fi
		fi
	done
	
	if [ $exitCode -ne 0 ]; then
		echo "Were not able to unmount all subfolders" >&2
	fi
	
	return $exitCode
}

function bindFolder()
#$1 path folder path containing mounted point subfolders
#$2 target folder path connecting the mounted points. I.e.: $path/Folder1 will be mounted as $target/Folder1
{
	local path="$1"
	local target="$2"
	if [ "$path" = "" ]; then
		echo "Missing first parameter \$path" >&2
		return 1
	fi
	if [ "$target" = "" ]; then
		echo "Missing second parameter \$target" >&2
		return 1
	fi
	if [ ! -d "$path" ]; then
		echo "\$path \"$path\" is not a folder" >&2
		return 2
	fi
	if [ ! -d "$target" ]; then
		echo "\$target \"$target\" is not a folder" >&2
		return 2
	fi
	
	#For each subfolders try to mount
	local exitCode=0
	for d in "$path"/*/; do
		local isMounted=$(ensureMount "$d")
		if [ "$isMounted" = "Y" ]; then continue; fi # Already mounted
		
		local folderName=$(basename "$d")
		local targetPath="$target/$folderName"
		
		if [ ! -d "$targetPath" ]; then continue; fi # Target is not a directory, so skip.
		
		mount --bind "$d" "$targetPath"
		if [ $? -ne 0 ]; then exitCode=$?; fi
	done
	
	if [ $exitCode -ne 0 ]; then
		echo "Were not able to mount all subfolders" >&2
	fi
	
	return $exitCode
}

function ensureMount()
#$1 path Path to test if it is a mounting point
{
	local path="$1"
	if [ "$path" = "" ]; then
		echo "Missing first parameter \$path" >&2
		return 1
	fi
	
	if [ ! -d "$path" ]; then
		echo "\"$path\" is not a directory" >&2
		return 2
	fi
	
	local realPath=$(getRealPath "$path")
	local isMounted=$(mount | grep "$realPath ")
	if [ "$isMounted" = "" ]; then
		echo "N"
	else
		echo "Y"
	fi
}

function waitMount()
#$1 path Path to test if it is a mounting point
{
	local path="$1"
	local isMounted="N"
	while [ "$isMounted" != "Y" ]; do
		isMounted=$(ensureMount "$path")
		sleep 2
	done
}

function turnOffBinding()
#$1 configName
{
	local configName="$1"
	
	if [ "$(isBindingEnabled "$configName")" != "Y" ]; then return; fi
	
	loadConfiguration "$configName"
	unbindFolder "$SHARED_FOLDER"
	local exitCode=$?
	
	if [ $exitCode -ne 0 ]; then return $?; fi
	
	screen -d -m $0 --off-loop-cfg "$configName" 2>&1 1>/dev/null
	
	return 0
}

function turnOnBinding()
#$1 configName
{
	local configName="$1"
	if [ "$(isBindingEnabled "$configName")" = "Y" ]; then return; fi
	
	loadConfiguration "$configName"	
	bindFolder "$SHARED_FOLDER" "$MOUNT_POINT"
	if [ $? -ne 0 ]; then return $?; fi
	
	local scriptFileName=$(basename "$0")
	ps | grep "$scriptFileName --off-loop-cfg $configName" | awk '{print $1}' | xargs kill -9 2>/dev/null # Ignore trying to kill self grep
}

function loadConfiguration()
#$1 configName
{
	local configName="$1"
	local configFile="$mountLibConfigFolder$configName.cfg"
	if [ ! -f "$configFile" ]; then
		echo "Config \"$configName\" doesn't exist" >&2
		return 1
	fi
	
	# Reset configuration
	read -r -d '' resetConfigContent <<- EOM
		DISABLED=N
		TYPE=
		OPTIONS=
		SHARED_FOLDER=
		MOUNT_POINT=
		WAIT_REMOTE_HOST=
		WAIT_REMOTE_USER=
		WAIT_REMOTE_MOUNT=
		WAIT_REMOTE_TIME=30
		WAIT_REMOTE_MAX_LOOP=10
		TURN_OFF_BIND_HOST=
		TURN_OFF_BIND_USER=
		TURN_OFF_BIND_CFG=
		TURN_OFF_BIND_TIME=10
		TURN_OFF_BIND_MAX_LOOP=10
	EOM
	
	if [ ! -f "$mountLibDefaultConfigFile" ]; then
		#Create default configuration
		printf "$resetConfigContent" > $mountLibDefaultConfigFile
	fi
	
	#Using "eval" instead of "source" to ensure config file is using Linux ending line style
	eval "$resetConfigContent" # Reset all configuration values
	eval "$(tr -d '\015' < "$mountLibDefaultConfigFile")" # Apply default values
	eval "$(tr -d '\015' < "$configFile")" # Load desired configuration
}

function isBindingEnabled()
#$1 configName
{
	local configName="$1"
	
	if [ ! -f "$mountLibConfigFolder$configName.cfg" ]; then
		echo "Config \"$configName\" doesn't exist" >&2
		return
	fi
	
	local scriptFileName=$(basename "$0")
	local isLoopRunning=$(ps | grep "$scriptFileName --off-loop-cfg $configName" | wc -l)
	
	if [ $isLoopRunning -lt 2 ]; then
		echo "Y"
	else
		echo "N"
	fi
}

function sendRemoteCommand()
#$1 remoteUser User that will execute the command on the remote machine
#$2 host Host name to connect to
#$3 maxRetries Number of maximum retries
#$4 timeBetweenRetries Time in seconds to wait before trying again
#$5 commandName Command to send to remote mount scriptFileName
#$6 commandParams Parameters to send with command
#$7 expectedResults Results to be expected by the command return
#
{
	local remoteUser="$1"
	local host="$2"
	local maxRetries="$3"
	local timeBetweenRetries="$4"
	local commandName="$5"
	local commandParams="$6"
	local expectedResults="$7"

	local waitedLoop=0
	local isMounted=""
	local sshResults=""
	if [ "$expectedResults" = "" ]; then sshResults="FAKE"; fi # Ensure first loop is done if expected results is an empty string
	while [ "$sshResults" != "$expectedResults" ] && [ $waitedLoop -lt $maxRetries ];
	do
		# -o BatchMode=yes to ensure no credential asked
		sshResults=$(ssh -o BatchMode=yes $remoteUser@$host "/share/homes/scripts/$(basename "$0") $commandName $commandParams")
		local sshExitCode=$?
		
		if [ $sshExitCode -ne 0 ]; then
			echo "Remote ssh command failed: \"$commandName $commandParams\"" >&2
			return $sshExitCode
		fi
		
		if [ "$sshResults" != "$expectedResults" ]; then
			sleep $timeBetweenRetries
			waitedLoop=$((waitedLoop + 1))
		fi
	done
	
	echo "$sshResults"
	return 0
}

function mountConfigs()
{
	## Configuration files existance test
	if [ ! -d "$mountLibConfigFolder" ]; then
		echo "\"$mountLibConfigFolder\" folder is missing" >&2
		exit 1
	fi

	nbConfigFiles=$(ls "$mountLibConfigFolder" | wc -c)
	if [ $nbConfigFiles -eq 0 ]; then
		echo "No configuration file in \"$mountLibConfigFolder\"" >&2
		exit 1
	fi
	
	configsFiles=$(ls $mountLibConfigFolder)
	
	for configFile in $configsFiles; do	
		configFile="$mountLibConfigFolder$configFile"
		
		local configName=$(basename "$configFile")
		configName=${configName%????} # Remove extension
		if [ "$configFile" = "$mountLibDefaultConfigFile" ]; then continue; fi
		
		loadConfiguration "$configName"
		
		if [ "$DISABLED" = "Y" ]; then continue; fi # Skip because config disabled
		if [ "$SHARED_FOLDER" = "" ]; then continue; fi # Skip missing mandatory info
		if [ "$MOUNT_POINT" = "" ]; then continue; fi # Skip missing mandatory info
		
		if [ "$TYPE" = "bind" ]; then
			local alreadyMounted=$(ensureMount "$MOUNT_POINT")
			if [ "$alreadyMounted" = "Y" ]; then continue; fi # Skip, already mounted
			
			local sharedFolder="$SHARED_FOLDER"
			local mountPoint="$MOUNT_POINT"
			local turnOffBindCfg="$TURN_OFF_BIND_CFG"
			
			if [ "$turnOffBindCfg" != "" ]; then
				echo "Turning off \"$turnOffBindCfg\""
				loadConfiguration "$turnOffBindCfg"
				unbindFolder "$SHARED_FOLDER" "$MOUNT_POINT"
			fi
			
			echo "Binding \"$configFile\""
			mount --bind "$sharedFolder" "$mountPoint"
			
			if [ "$turnOffBindCfg" != "" ]; then
				echo "Turning on \"$turnOffBindCfg\""
				bindFolder "$SHARED_FOLDER" "$MOUNT_POINT"
			fi
		elif [ "$TYPE" = "bind-folder" ]; then
			local shallBind="Y"
			if [ "$WAIT_REMOTE_HOST" != "" ] && [ "$WAIT_REMOTE_USER" != "" ] && [ "$WAIT_REMOTE_MOUNT" != "" ]; then
				echo "Verifying \"$WAIT_REMOTE_MOUNT\" on \"$WAIT_REMOTE_HOST\""
				
				local sshResults=$(sendRemoteCommand "$WAIT_REMOTE_USER" "$WAIT_REMOTE_HOST" "$WAIT_REMOTE_MAX_LOOP" "$WAIT_REMOTE_TIME" "--is-mounted" "\"$WAIT_REMOTE_MOUNT\"" "Y")
				local exitCode=$?
				if [ $exitCode -ne 0 ]; then shallBind="N"; fi				
				if [ "$sshResults" != "Y" ]; then shallBind="N"; fi
			fi
			
			if [ $(isBindingEnabled "$configName") != "Y" ]; then shallBind="N"; fi
			
			if [ "$shallBind" = "Y" ]; then
				echo "Mounting $configFile"
				bindFolder "$SHARED_FOLDER" "$MOUNT_POINT"
			fi
		else
			local alreadyMounted=$(ensureMount "$MOUNT_POINT")
			if [ "$alreadyMounted" = "Y" ]; then continue; fi # Skip, already mounted
			
			local shallMount="Y"
			local turnOffBind="N"
			if [ "$TURN_OFF_BIND_HOST" != "" ] && [ "$TURN_OFF_BIND_USER" != "" ] && [ "$TURN_OFF_BIND_CFG" != "" ]; then
				### Turning off solution only works for static directory (not adding/removing subfolders)
				turnOffBind="Y"
			fi
			
			# Turn off remote bind if needed
			if [ "$turnOffBind" = "Y" ]; then
				local sshResults=$(sendRemoteCommand "$TURN_OFF_BIND_USER" "$TURN_OFF_BIND_HOST" "$TURN_OFF_BIND_MAX_LOOP" "$TURN_OFF_BIND_TIME" "--turn-off-bind-folder" "\"$TURN_OFF_BIND_CFG\"" "")
				if [ $exitCode -ne 0 ]; then shallMount="N"; fi
			fi
			
			if [ "$shallMount" != "Y" ]; then continue; fi
			
			# Do mounting
			local mountArgs=()
			if [ "$TYPE" != "" ]; then mountArgs+=(-t "$TYPE"); fi
			if [ "$OPTIONS" != "" ]; then mountArgs+=(-o "$OPTIONS"); fi
			
			echo "Mounting $configFile"
			mountArgs+=("$SHARED_FOLDER");
			mountArgs+=("$MOUNT_POINT");
			
			mount "${mountArgs[@]}"
			
			if [ "$turnOffBind" = "Y1" ]; then
				sleep 30 # 3 seconds not enough, but 30 is
				local sshResults=$(sendRemoteCommand "$TURN_OFF_BIND_USER" "$TURN_OFF_BIND_HOST" "$TURN_OFF_BIND_MAX_LOOP" "$TURN_OFF_BIND_TIME" "--turn-on-bind-folder" "\"$TURN_OFF_BIND_CFG\"" "")
			fi
		fi
	done

	exit
}