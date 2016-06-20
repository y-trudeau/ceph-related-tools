The wsrep_sst_ceph script allows to perform an SST using Ceph snapshots.  The script could easily be generalized to other forms of snapshots that can be accessed by multiple hosts (SAN, EBS, etc.).

Installation
============

Copy the script to /usr/bin and make sure is it executable by the mysql user only and writable only by root.  Here are the steps::

	wget -O /usr/bin/wsrep_sst_ceph https://github.com/y-trudeau/ceph-related-tools/raw/master/wsrep-sst/wsrep_sst_ceph
	chown mysql.mysql /usr/bin/wsrep_sst_ceph
	chmod 500 /usr/bin/wsrep_sst_ceph
	mkdir /var/lib/galera
	chown mysql.mysql /var/lib/galera

I choose to create /var/lib/galera to hold the galera specific files that needs to be out of the normal datadir because the snapshots will be mounted on top of them.  Make sure there's sufficient disk space in the partition for the gcache file.

You will also need a version of Percona XtraDB cluster that has the following pull requests applied::

    https://github.com/percona/percona-xtradb-cluster/pull/128

As of June 2016, it is still the pending state.

ceph
----

Each nodes must get configured for Ceph and have a CephX key allowing 'rwx' on the pools you are planning to use.


my.cnf
------

Here are the variables specific to the Ceph SST operation.  These are defined in the [sst] section of the my.cnf file.


cephlocalpool
    The Ceph pool where this node should create the clone.  It can be a different pool from the one of the original dataset.  For example, it could have a replication factor of 1 (no replication) for a read scaling node.  The default value is: mysqlpool

cephmountpoint
    What is mount point to use.  It defaults to the MySQL datadir as provided to the SST script.

cephmountoptions
    The options used to mount the filesystem.  The default value is: rw,noatime

cephkeyring
    The Ceph keyring file to authenticate against the Ceph cluster with cephx.  The user under which MySQL is running must be able to read the file.  The default value is: /etc/ceph/ceph.client.admin.keyring

cephcleanup
    Wether or not the script should cleanup the snapshots and clones that are no longer is used.  Enable = 1, Disable = 0. The default value is: 0


In addition to these settings, a few variables must be set correctly in the [mysqld] section.  First, you **must** set the base_dir wsrep provider option outside of the directory where you'll be mounting the MySQL datadir.  This is because galera opens files in that directory prior to the mount and those file would then be hidden under the mount point.  Here's a more complete example::

    [mysqld]
    datadir=/var/lib/mysql
    wsrep_provider=/usr/lib/libgalera_smm.so
    wsrep_provider_options="base_dir=/var/lib/galera"
    wsrep_cluster_address=gcomm://10.0.5.120,10.0.5.47,10.0.5.48
    wsrep_node_address=10.0.5.48
    wsrep_sst_method=ceph
    wsrep_cluster_name=ceph_cluster

    [sst]
    cephlocalpool=mysqlpool
    cephmountoptions=rw,noatime,nodiratime,nouuid
    cephkeyring=/etc/ceph/ceph.client.admin.keyring
    cephcleanup=1
