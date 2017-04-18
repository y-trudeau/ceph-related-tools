#!/bin/bash
#
# mysql_make_me_slave.sh version v 0.1 2017-04-07
# Yves Trudeau, Percona
# Runs through the steps of setting up a slave from 
# a Ceph snapshot
#
# 
DEBUGFILE="/tmp/mysql-make-me-slave.log"
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
GREP=`which grep`
SSH=`which ssh`
CUT=`which cut`
MYSQL=`which mysql`
ECHO=`which echo`
AWK=`which awk`
SED=`which sed`
MY_PRINT_DEFAULTS=`which my_print_defaults`
SYSTEMCTL=`which systemctl`
MKTEMP=`which mktemp`
MOUNT=`which mount`
UMOUNT=`which umount`
CP=`which cp`
RM=`which rm`
CHOWN=`which chown`
TEE=`which tee`

# Default values
master=''
vflag=0
mysqluser='root'
mysqlpass=''
masterport=3306
repluser='repl'
replpass=''
gtid=$($MY_PRINT_DEFAULTS mysqld | $GREP -i gtid_mode | $CUT -d'=' -f2)
cephpool=
cephid='admin'
cephkeyring='/etc/ceph/ceph.client.admin.keyring'
loginpath=''
socket=$($MY_PRINT_DEFAULTS mysqld | $GREP socket | $CUT -d'=' -f2)
mysqldatadir=$($MY_PRINT_DEFAULTS mysqld | $GREP datadir | $CUT -d'=' -f2)
snaptoolpath="/usr/local/bin/mysql-ceph-snap.sh"
systemdservice='mysql'

# go through passed options and assign to variables
while getopts 'm:vgd:u:p:c:k:i:l:s:S:P:U:t:h' OPTION
do
        case $OPTION in
        m)      master="$OPTARG"
                ;;
        v)      vflag=1
                ;;
        g)      gtid='ON'
                ;;
        d)      mysqldatadir="$OPTARG"
                ;;
        u)      mysqluser="$OPTARG"
                ;;
        p)      mysqlpass="$OPTARG"
                ;;
        c)      cephpool="$OPTARG"
                ;;
        k)      cephkeyring="$OPTARG"
                ;;
        i)      cephid="$OPTARG"
                ;;
        l)      loginpath="$OPTARG"
                ;;
        s)      systemdservice="$OPTARG"
                ;;
        S)      socket="$OPTARG"
                ;;
        P)      replpass="$OPTARG"
                ;;
        U)      repluser="$OPTARG"
                ;;
        t)      snaptoolpath="$OPTARG"
                ;;
        h|?)      printf "Usage: %s: [-h] [-v] [-g] -m master [-u <mysql admin user> -p <mysql admin pass> | -l <login-path>] [-c <ceph destination pool>] [-U <mysql replication user>] [-P <mysql replication password>] [-l <login-path>] [-S <mysql socket>] [-i <Ceph id>] [-k <Ceph keyring>] [-d <mysql datadir> ] [ -t <snap tool path>]\n\n
        -h\t\tThis help
        -v\t\tVerbose mode, otherwise quiet
        -g\t\tForce gtid mode, default is use what my_print_defaults returns
	-m\t\tMaster IP or resolvable hostname (MANDATORY)
	-u\t\tMySQL admin user, used to setup replication and for the master snapshot (default = root)
	-p\t\tMySQL admin password, used to setup replication and for the master snapshot (default is empty)
	-c\t\tCeph destination pool for the clone, the pool must exists (default = pool used by the master)
	-U\t\tMySQL replication user  (default = repl)
	-P\t\tMySQL replication password (default is empty)
	-l\t\tMySQL admin login path. If presents options -u and -p are ignored. Must be valid for the master and the slave.
	-s\t\tSystemd service name, (default = mysql)
	-S\t\tMySQL socket, default is use what my_print_defaults returns
	-i\t\tCeph authx id (default = admin)
	-k\t\tCeph authx keyring (default = /etc/ceph/ceph.client.admin.keyring)
	-d\t\tMySQL datadir, default is use what my_print_defaults returns
	-t\t\tPath to the mysql_ceph_snap.sh script (default = /usr/local/bin/mysql_ceph_snap.sh)
	  \t\tThe user running the script must have passwordless ssh access to the master and sudo on both the master and the slave
"$(basename $0) 
		exit 1
		;;
	esac
done
if [ "$vflag" ]; then
        $ECHO "Processing options" 
fi

if [ ! -d "$mysqldatadir" ]; then
    $ECHO "Mysql datadir: $datadir doesn't exist"
    exit 1
fi

if [ -z "$master" ]; then
	$ECHO "A master IP or hostname must be provided"
	exit 1
else
	$ECHO $master | $GREP ':' > /dev/null
	if [ "$?" -eq 0 ]; then
		MYSQLMASTEROPTION="-h $($ECHO $master | $CUT -d':' -f1) "
		MYSQLMASTEROPTION="$MYSQLMASTEROPTION -P $($ECHO $master | $CUT -d':' -f2) "
	else
		MYSQLMASTEROPTION="-h $master "
	fi
fi

MYSQLOPTIONS="-N -n "

if [ -z "$loginpath" ]; then
        if [ -z "$mysqluser" ]; then
                $ECHO "MySQL user or login-path must be provided"
                exit 1
        else
                MYSQLOPTIONS="$MYSQLOPTIONS -u $mysqluser "
                if [ ! -z "$password" ]; then
                        MYSQLOPTIONS="$MYSQLOPTIONS -p$password "
                fi
        fi
else
        MYSQLOPTIONS=" --login-path=$loginpath $MYSQLOPTIONS "
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

if [ "$USER" == "root" ]; then
	SUDO=
else
	SUDO=$(which sudo)
fi
# must stop mysql, umount and unmap previous ceph image

IsMySQLRunning=$($SYSTEMCTL is-active $systemdservice)
if [ "$IsMySQLRunning" == "active" ]; then
	if [ "$vflag" ]; then
        $ECHO "Stopping MySQL" 
	fi
	$SUDO $SYSTEMCTL stop $systemdservice
fi

# check if we need to preserve the auto.cnf file
if [ -f "$mysqldatadir/auto.cnf" ]; then
	tmpAutocnf=$(mktemp MakeMeSlave.XXXXXXXXXX)
	$SUDO $CP $mysqldatadir/auto.cnf $tmpAutocnf
fi	

rbddev=$(df -P $mysqldatadir | grep $mysqldatadir | awk '{ print $1 }')
if [ ! -z "$rbddev" ]; then
	#is it really an rbd device
	$ECHO $rbddev | $GREP rbd > /dev/null
	if [ "$?" -eq 1 ]; then
   		$ECHO "Device mounted on $mysqldatadir is not an RBD device. If that is correct, manually umount it prior to running this script."
   		exit 1
	fi

	if [ "$vflag" ]; then
        $ECHO "Unmounting $mysqldatadir" 
	fi

	$SUDO $UMOUNT $mysqldatadir
	if [ "$?" -ne 0 ]; then
   		$ECHO "Couldn't umount $mysqldatadir, investigate and fix the issue."
   		exit 1
	fi

	if [ "$vflag" ]; then
        $ECHO "Unmapping the rbd device $rbddev" 
	fi
    
    $SUDO $RBD $RBDOPTIONS unmap $rbddev 
	if [ "$?" -ne 0 ]; then
   		$ECHO "Couldn't unmap the RBD device $rbddev, investigate and fix the issue."
   		exit 1
	fi
fi

if [ "$vflag" ]; then
        $ECHO "SSHing the master to create a snapshot" 
fi

SNAP=`$SSH -t $master "$SUDO $snaptoolpath -u $mysqluser -P $mysqlpass -c $(uname -n) -b custom -R 1" 2>/dev/null`

$ECHO "$SNAP" | $GREP 'SNAPSHOT' > /dev/null
if [ "$?" -eq 1 ]; then
   $ECHO "Couldn't get the snapshot from the master"
   exit 1
fi

#SNAP is like 'SNAPSHOT=MysqlRepl/master@ceph-node2.localdomain_Time-2017-03-31T15:32:52'

CEPHSNAP=$($ECHO $SNAP | $CUT -d'=' -f2 | $SED 's/\r$//' )
if [ -z $CEPHSNAP ]; then
   $ECHO "Empty Ceph snapshot"
   exit 1
fi


CEPHIMAGE=$($ECHO $CEPHSNAP | $CUT -d'@' -f1 )
CEPHMASTERPOOL=$($ECHO $CEPHIMAGE | $CUT -d'/' -f1)

if [ -z $cephpool ]; then
	cephpool=$CEPHMASTERPOOL
fi

if [ "$vflag" ]; then
        $ECHO "Snapshot taken, protecting it" 
fi

$RBD $RBDOPTIONS snap protect $CEPHSNAP > /dev/null
if [ "$?" -ne 0 ]; then
   $ECHO "Couldn't protect the snapshot $CEPHSNAP"
   exit 1
fi

if [ "$vflag" ]; then
        $ECHO "Snapshot protected, cloning it" 
fi

#Verify there is not an existing clone 
CloneExists=$($RBD $RBDOPTIONS -p $cephpool ls | $GREP -c clone-$(uname -n))
if [ "$CloneExists" -gt 0 ]; then
	if [ "$vflag" ]; then
        	$ECHO "The clone $cephpool/clone-$(uname -n) already exists, attempting to delete it" 
	fi
	$RBD $RBDOPTIONS rm $cephpool/clone-$(uname -n)
	if [ "$?" -ne 0 ]; then
   		$ECHO "Couldn't remove the clone $cephpool/clone-$(uname -n)"
		exit 1
	fi
fi
	

$RBD $RBDOPTIONS clone $CEPHSNAP $cephpool/clone-$(uname -n) > /dev/null
if [ "$?" -ne 0 ]; then
   $ECHO "Couldn't clone the snaphot $CEPHSNAP to $cephpool/clone-$(uname -n)"
   exit 1
fi

rbddev=$($SUDO $RBD $RBDOPTIONS map $cephpool/clone-$(uname -n))
if [ "$?" -ne 0 ]; then
   $ECHO "Couldn't map $cephpool/clone-$(uname -n)"
   exit 1
fi

if [ "$vflag" ]; then
        $ECHO "Clone $cephpool/clone-$(uname -n) mapped to $rbddev" 
fi

$SUDO $MOUNT $rbddev $mysqldatadir -o noatime,nodiratime
if [ "$?" -ne 0 ]; then
   $ECHO "The mount of the device $rbddev to $mysqldatadir failed"
   exit 1
fi

# do we have to copy back the auto.cnf file
if [ ! -z "$tmpAutocnf" ]; then
	$SUDO $CP $tmpAutocnf $mysqldatadir/auto.cnf 
	$SUDO $RM -f $tmpAutocnf
else
	$ECHO -e "[auto]\nserver-uuid=$(uuidgen)" | $SUDO $TEE $mysqldatadir/auto.cnf > /dev/null
	$SUDO $CHOWN mysql.mysql $mysqldatadir/auto.cnf
fi

if [ "$vflag" ]; then
        $ECHO "Starting Mysql" 
fi

$SUDO $SYSTEMCTL start $systemdservice

IsMySQLRunning=$($SYSTEMCTL is-active $systemdservice)
if [ "$IsMySQLRunning" == "active" ]; then
	if [ "$vflag" ]; then
        $ECHO "MySQL is running" 
	fi
else
   $ECHO "MySQL failed to start"
   exit 1
fi

$ECHO $gtid | $GREP -i on > /dev/null

if [ "$?" -eq 0 ]; then
	#gtid mode
	$MYSQL $MYSQLOPTIONS -e "stop slave; reset slave all;change master to master_host='$master', master_user='$repluser', master_password='$replpass', MASTER_AUTO_POSITION = 1;start slave;"
else
	binlogfile=$($AWK '{print $1}' $mysqldatadir/snap_master_pos.out)
	binlogpos=$($AWK '{print $2}' $mysqldatadir/snap_master_pos.out)
	$MYSQL $MYSQLOPTIONS -e "stop slave; reset slave all;change master to master_host='$master', master_user='$repluser', master_password='$replpass', master_log_file='$binlogfile', master_log_pos=$binlogpos;start slave;"
fi

