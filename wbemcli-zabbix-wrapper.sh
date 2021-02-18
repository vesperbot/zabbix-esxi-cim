#!/bin/bash
NAMESPACE="root/cimv2"
REQUESTHELP=0
DISCOVERY=0
[ -z "$DEBUG" ] && DEBUG=0
if [ ! -f `which wbemcli` ]; then
    echo "wbemcli not found in path! Please install wbemcli."
    exit 1
fi
function unquote() {
    key="$1"
    if [[ $key =~ ^\".*\"$ ]]; then
        key=${key#\"}
        key=${key%\"}
        # strip extra quotes if passed
    else if [[ $key =~ ^\'.*\'$ ]]; then
        key=${key#\'}
        key=${key%\'}
    fi
    fi
unquote_return=$key # bash can't return a string
}
    # old-style bash parameter parsing, using "-key value" syntax
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
        unquote "$1"
        key=$unquote_return
        case $key in
        -u|--user)
          unquote "$2"
          USERNAME=$unquote_return
          shift # past argument
          shift # past value
        ;;
        -p|--password)
          unquote "$2"
          PASSWORD=$unquote_return
          shift # past argument
           shift # past value
        ;;
        -s|--host|--server)
          unquote "$2"
          TARGET=$unquote_return
          shift # past argument
          shift # past value
        ;;
        -c|--class)
          unquote "$2"
          CLASS=$unquote_return
          shift # past argument
          shift # past value
        ;;
        -n|--namespace)
          unquote "$2"
          NAMESPACE=$unquote_return
          shift # past argument
          shift # past value
        ;;
        --discovery)
          DISCOVERY=1
          shift # past argument
        ;;
        -i|--item)
          unquote "$2"
          ITEM=$unquote_return
          shift # past argument
          shift # past value
        ;;
        -h|--help)
          REQUESTHELP=1
          shift # past argument
        ;;
        *)    # unknown option
          POSITIONAL+=("$1") # save it in an array for later
          shift # past argument
        ;;
        esac
    done
EXITSTATUS=0
[ $DEBUG -eq 1 ] && echo "${#POSITIONAL[@]} positional arguments"
if [[ ${#POSITIONAL[@]} -ne 0 && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "Unknown arguments: ${POSITIONAL[@]}"
fi
if [[ $TARGET == "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "Host name or IP address should be specified"
fi
if [[ $USERNAME == "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "User name should be specified"
fi
if [[ $PASSWORD == "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "Password should be specified"
fi
if [[ $CLASS == "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "CIM class name should be specified"
fi
if [[ $DISCOVERY -eq 1 && $ITEM != "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "Specifying --discovery and --item is conflicting"
fi
if [[ $DISCOVERY -eq 0 && $ITEM == "" && $REQUESTHELP -eq 0 ]]; then
    EXITSTATUS=1
    REQUESTHELP=1
    echo "Specify either --discovery or --item"
fi
if [[ $DEBUG -eq 1  ]]; then
    echo "DEBUG MODE:
Username = $USERNAME
Password = $PASSWORD
Host = $TARGET
Namespace = $NAMESPACE
Class = $CLASS  "
    if [ $DISCOVERY -eq 1 ]; then
        echo "Discovery mode"
    else
        echo "Item = $ITEM"
    fi
fi
if [ $REQUESTHELP == 1 ]; then
    echo "
Usage: Supply all the following arguments:
    -h or --host or --server (value): IP or DNS name of host to query
    -u or --username: User name to connect to target WBEM interface
    -p or --password: Password
    -c or --class: CIM class name (see documentation to system you're querying)
    -n or --namespace: CIM namespace (defaults to root/cimv2)

Optional parameters:
    --discovery: Makes this script produce Zabbix-accepted discovery output
    -i or --item: Queries a specific item. Conflicts with --discovery
    "
    exit $EXITSTATUS
fi
if [ $DISCOVERY -eq 1 ]; then
    # discovery mode
    ITEMS=`wbemcli ein -noverify "https://$USERNAME:$PASSWORD@$TARGET/$NAMESPACE:$CLASS" 2>&1`
#    RETURNCODE=$?
#    [ $RETURNCODE -ne 0 ] && echo "ZBX_UNSUPPORTED: $TARGET/$NAMESPACE:$CLASS $ITEMS"
#    [ $RETURNCODE -ne 0 ] && exit $RETURNCODE
    # wbemcli does not return exit code, instead it throws some lines with errors in plain text
    # but it does so in error stream, so capturing it is required
    #echo "$ITEMS" # placeholder
    if [[ "$ITEMS" =~ ^\s*\* ]]; then
        # wbemcli returned a star - this means we've got an error
        echo "ZBX_UNSUPPORTED: $ITEMS"
        exit 1
    fi
    echo ' { "data": [ ' # JSON start
    isfirst=1
    for item in `echo $ITEMS`; do
        [ $isfirst -ne 1 ] && echo  ','
        # normal discovery, item is returned as a full link but without user/pass
        # have to now filter harder - just "last dot" no longer cuts this, as some vendors return dots in values
        # this filter: first skips until 2 semicolons as in "username:password@host:port" then skips until first dot
        itemfilter=`echo $item | sed  's/^[^:]*:[^:]*:[^\.]*\.\(.*\)/\1/'`
        # old filter:
#         itemfilter=`echo $item | sed "s/.*\.\([^.]*\)$/\1/"`
        # example of itemfilter: SystemCreationClassName="ARC_ControllerComputerSystem",SystemName="arcController_0",CreationClassName="ARC_DiskDrive",DeviceID="0_0_0"
        # Problem is, we need to retrieve the disk class as well, otherwise "get-item" doesn't work
        # need to make device name from whatever classes are in here that aren't saying "class"
        # echo "Hum $item"
        fullname=""
        deviceclass=""
        altfilter="" # filter by class creation is excess, gonna filter by instances only
        for class in ${itemfilter//,/$'\n'}; do
            # echo "Class split $class"
            classname=${class%%=*}
            classvalue=${class##*=}
            # these are substring "remove largest suffix/prefix" bash operators. Perfectly suitable here
            [[ $classname == "CreationClassName" ]] && deviceclass="$classvalue"
            if [[ ! $classname =~ Class ]]; then
                # use this class value to build a name
                if [[ $fullname == "" ]]; then
                    fullname="$classvalue"
                else
                    fullname=`echo "${fullname}_${classvalue}"`
                    # bash cannot concat strings!!!11 At least it can grab echo
                fi
                if [[ $altfilter == "" ]]; then
                    altfilter="$class"
                else
                    altfilter=`echo "${altfilter},${class}"`
                fi
            fi
        done
        altfilter=`echo "$altfilter" | sed 's/\"/\\\"/g'` # escape filter as it contains double quotes, or else
        fullname=`echo $fullname | sed 's/\"//g'`
        deviceclass=`echo $deviceclass | sed 's/\"//g'`
        #echo "Name constructed: $fullname"
        echo -n "{ \"{#ITEMNAME}\":\"$fullname\", \"{#ITEMPATH}\":\"$altfilter\", \"{#ITEMCLASS}\":\"$deviceclass\" }"
        isfirst=0
    done
    echo ' ] } '
else
    # simple call to wbemcli
    # in case of http WBEM endpoint, drop "noverify" switch
    # DEBUG=1 # currently discovery works so not interfering
    # surprise, namespace does NOT retrieve items for "CIM_DiskDrive" instead it returns 
    # classes for items found as "ARC_DiskDrive". FFFFUUUUU-
    [ $DEBUG -eq 1 ] && echo -n "DEBUG: https://$USERNAME:$PASSWORD@$TARGET/$NAMESPACE:$CLASS.$ITEM "
    OUTPUT=`wbemcli gi -noverify "https://$USERNAME:$PASSWORD@$TARGET/$NAMESPACE:$CLASS.$ITEM" 2>&1`
    echo "$OUTPUT"
    exit $?
fi
