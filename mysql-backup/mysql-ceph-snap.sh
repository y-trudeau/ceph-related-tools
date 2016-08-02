#!/bin/bash
#
# mysql_ceph_snap.sh version v 0.1 2016-07-24
# Yves Trudeau, Percona
# Inspired by zfs_snap of Nils Bausch
#
# take EBS snapshots with a time stamp
# -h help page
# -d choose default options: hourly, daily, weekly, monthly, yearly
# -i image path, pool/image  
# -m mysql mount point
# -v verbose output
# -p pretend - don't take snapshots
# -S mysql socket
# -u user mysql user
# -P mysql password 
# -w warmup script
# -x cephX auth file

DEBUGFILE="/tmp/mysql-ebs-snap.log"
if [ "${DEBUGFILE}" -a -w "${DEBUGFILE}" -a ! -L "${DEBUGFILE}" ]; then
        exec 9>>"$DEBUGFILE"
        exec 2>&9
        date >&9
        echo "$*" >&9
        set -x
else
        echo 9>/dev/null
fi
export PATH=$PATH:/sbin:/usr/sbin
# Path to binaries used
RBD=`which rbd`
EGREP=`which egrep`
GREP=`which grep`
TAIL=`which tail`
SORT=`which sort`
XARGS=`which xargs`
DATE=`which date`
CUT=`which cut`
TR=`which tr`
MYSQL=`which mysql`
ECHO=`which echo`
AWK=`which awk`

# set default values
DEFAULTOPT=custom
customretention=99999
PREFIX="MySQL"
LABEL=`${DATE} +"%FT%H:%M"`
vflag=
pflag=
rflag=0
socket=
mysql_user=
password=
loginpath=
cephimage=
cephkeyring=
warmup=
mysqlmount=/var/lib/mysql

# go through passed options and assign to variables
while getopts 'hd:c:m:vpru:I:k:i:l:S:P:R:w:' OPTION
do
        case $OPTION in
        d)      DEFAULTOPT="$OPTARG"
                ;;
        c)      PREFIX="$OPTARG"
                ;;
        m)      mysqlmount="$OPTARG"
                ;;
        v)      vflag=1
                ;;
        p)      pflag=1
                ;;
        r)      rflag=1
                ;;
        u)      mysqluser="$OPTARG"
                ;;
        I)      cephimage="$OPTARG"
                ;;
        k)      cephkeyring="$OPTARG"
                ;;
        i)      cephid="$OPTARG"
                ;;
        l)      loginpath="$OPTARG"
                ;;
        S)      socket="$OPTARG"
                ;;
        P)      password="$OPTARG"
                ;;
        R)      customretention="$OPTARG"
                ;;
        w)      warmup="$OPTARG"
                ;;
        h|?)      printf "Usage: %s: [-h] -d <default-preset> [-v] [-p] [-r] [-R <custome retention>] [-u <mysql user>] [-P <mysql password>] [-l <login-path>] [-S <mysql socket>] [-i <Ceph image path, ex: pool/image >] [-m <mysql datadir> [-w <warmup sql script>]\n\n
	-h\t\tThis help
	-d\t\tDefault preset {hourly,daily,weekly,monthly,yearly,timely} (Mandatory)
	  \t\tName\tLabel\tretention
	  \t\t-------------------------
	  \t\thourly\tAutoH\t24
	  \t\tdaily\tAutoD\t7
	  \t\tweekly\tAutoW\t4
	  \t\tmonthly\tAutoM\t12
	  \t\tyearly\tAutoM\t10
	  \t\tcustom\tTime\tfrom -R option (default)
	-R\t\tCustom retention, default = 99999
	-c\t\tCustom prefix (Default = MySQL)
	-v\t\tVerbose mode
	-p\t\tPretend mode, fake actions
	-u\t\tMySQL user (Mandatory or -l) 
	-P\t\tMySQL password (Mandatory or -l) 
	-l\t\tMySQL 5.6+ login-path, execludes -u and -P (Mandatory or -u and -P), overrides -u and -p
	-S\t\tMySQL socket (Mandatory)
	-I\t\tCeph image path which is used by MySQL (Mandatory)
	-k\t\tCephX keyring file
	-i\t\tCephX id 
	-r\t\tReplace the snapshot if a snapshot of that name already exists
	-m\t\tMySQL datadir (Mandatory)
	-w\t\tWarmup script, typically useful for MyISAM tables after the flush tables 
"$(basename $0) >&2
                exit 2
                ;;
        esac
done


if [ "$vflag" ]; then
        echo "Processing options" 
fi

# go through possible presets if available
if [ -n "$DEFAULTOPT" ]; then
        case $DEFAULTOPT in
        hourly) LABELPREFIX="${PREFIX}_AutoH"
                LABEL=`${DATE} +"%FT%H:%M"`
                retention=24
                ;;
        daily)  LABELPREFIX="${PREFIX}_AutoD"
                LABEL=`${DATE} +"%F"`
                retention=7
                ;;
        weekly) LABELPREFIX="${PREFIX}_AutoW"
                LABEL=`${DATE} +"%Y-%U"`
                retention=4
                ;;
        monthly)LABELPREFIX="${PREFIX}_AutoM"
                LABEL=`${DATE} +"%Y-%m"`
                retention=12
                ;;
        yearly) LABELPREFIX="${PREFIX}_AutoY"
                LABEL=`${DATE} +"%Y"`
                retention=10
                ;;
        custom) LABELPREFIX="${PREFIX}_Time"
                LABEL=`${DATE} +"%FT%H:%M:%S"`
                retention=$customretention
                ;;
        *)      printf 'Default option not specified\n'
                exit 2
                ;;
        esac
fi

MYSQLOPTIONS="-N -n "

if [ -z "$loginpath" ]; then
	if [ -z "$mysqluser" ]; then
		echo "MySQL user or login-path must be provided"
		exit 1
	else
		MYSQLOPTIONS="$MYSQLOPTIONS -u $mysqluser "
		if [ ! -z "$password" ]; then
			MYSQLOPTIONS="$MYSQLOPTIONS -p$password "
		fi
	fi
else
	MYSQLOPTIONS="$MYSQLOPTIONS --login-path=$loginpath "
fi

if [ ! -z "$socket" ]; then
	MYSQLOPTIONS="$MYSQLOPTIONS --socket=$socket "
fi

RBDOPTIONS=
if [ ! -z "$cephid" ]; then
	RBDOPTIONS="--id $cephid "
fi

if [ ! -z "$cephkeyring" ]; then
	RBDOPTIONS="$RBDOPTIONS --keyring $cephkeyring "
fi

if [ -z "$cephimage" ]; then
	echo "A Ceph image to snapshot must be provided"
	exit 1
fi

if [ -z "$pflag" ]; then

	SnapExists=$(${RBD} $RBDOPTIONS snap ls $cephimage | ${GREP} -c $LABELPREFIX-$LABEL)
	if [ "$SnapExists" -gt "0" ]; then
		if [ "$vflag" ]; then
        		echo "Snapshot with the name $LABELPREFIX-$LABEL already exists for $cephimage" 
		fi
		if [ "$rflag" -eq "1" ]; then
			if [ "$vflag" ]; then
        			echo "Replace option provided, removing snapshot $LABELPREFIX-$LABEL" 
			fi
			${RBD} $RBDOPTIONS snap rm $cephimage@$LABELPREFIX-$LABEL
		else
			exit
		fi		
	fi

	if [ "$vflag" ]; then
        	echo "Taking the snapshot" 
	fi

	if [ -d "${mysqlmount}" ]; then
	        $MYSQL $MYSQLOPTIONS > /${mysqlmount}/snap_master_pos.out <<EOF
flush tables with read lock;
SET GLOBAL innodb_buffer_pool_dump_now=ON;
flush logs;
show master status;
show slave status\G
\! sync
\! ${RBD} $RBDOPTIONS snap create $cephimage@$LABELPREFIX-$LABEL > /tmp/snap.log
EOF

	fi
fi

        if [ "$vflag" ]; then
                echo "Snapshot taken"
        fi

if [ "$warmup" ]; then
        cat $warmup |  $MYSQL $MYSQLOPTIONS &
fi

#DELETE SNAPSHOTS
# adjust retention to work with tail i.e. increase by one
let retention+=1

if [ "$vflag" ]; then
        echo "Looking for snapshots to delete" 
fi

list=`${RBD} $RBDOPTIONS snap ls $cephimage | ${GREP} $LABELPREFIX | \
${AWK} '{ print $2 }' | ${SORT} -r | ${TAIL} -n +${retention} | \
while read line; do ${ECHO} "$line "; done`

if [ ! -z "$pflag" ]; then
        if [ "${#list}" -gt 0 ]; then
                echo "Delete recursively:"
                echo "$list"
        else
                echo "No snapshots to delete"
        fi
else
        if [ "${#list}" -gt 0 ]; then
                for snap in $list; do 
                        if [ "$vflag" ]; then
                                echo "Deleting snapshot $snap"
                        fi
                        $RBD $RBDOPTIONS snap rm $cephimage@$snap
                done 
        fi
fi

