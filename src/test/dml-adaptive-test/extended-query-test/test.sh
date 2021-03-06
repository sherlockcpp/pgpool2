#!/usr/bin/env bash
#----------------------------------------------------------------------------------------
# test script for dml adaptive.
set -e

#---------------------------------------------------------------------------------------

HOST_IP="127.0.0.1"
WHOAMI=`whoami`
BASE_PORT=${BASE_PORT:-"11000"}
CLUSTERS_NUM=${CLUSTERS_NUM:-"2"}

BASE_DIR=$(cd `dirname $0`; pwd)
TEST_DIR=$BASE_DIR/tmp_testdir
LOG_FILE=$BASE_DIR/test.log

PG_INSTALL_PATH=${PG_INSTALL_PATH:-"/usr/local/pgsql"}
PG_USER=${PG_USER:-"postgres"}
PG_REPLICATION_USER=${PG_REPLICATION_USER:-"repl"}
PG_VERSION=""

#---------------------------------------------------------------------------------------

function check_version()
{
	echo "check PostgreSQL version ..."

	# get PostgreSQL major version
	vstr=`$PG_INSTALL_PATH/bin/initdb -V|awk '{print $3}'|sed 's/\./ /g'`

	set +e
	# check if alpha or beta
	echo $vstr|egrep "[a-z]" > /dev/null
	if [ $? = 0 ];then
		vstr=`echo $vstr|sed 's/\([0-9]*\).*/\1/'`
		major1=`echo $vstr|awk '{print $1}'`
		major2=`echo $vstr|awk '{print $2}'`
		if [ -z $major2 ];then
		major2=0
		fi
	else
		vstr=`echo $vstr|sed 's/\./ /g'`
		major1=`echo $vstr|awk '{print $1}'`
		major2=`echo $vstr|awk '{print $2}'`
	fi
	set -e

	major1=`expr $major1 \* 10`
	PG_VERSION=`expr $major1 + $major2`
	echo PostgreSQL major version: $PG_VERSION
	if [ $PG_VERSION -lt 100 ];then
		echo "in order to make the script run normally, please make sure PostgreSQL major version greater than 10.0"
		exit 1
	fi

	echo "check done."
}

#-------------------------------------------
# create PostgreSQL cluster
#-------------------------------------------
function initdb_primary_cluster()
{
	echo "initdb_primary_cluster ..."

	echo -n "creating database cluster $TEST_DIR/data-primary..."

	INITDB_ARG="--no-locale -E UTF_8"
	$PG_INSTALL_PATH/bin/initdb -D $TEST_DIR/data-primary $INITDB_ARG -U $PG_USER

	echo "done"
}

function set_primary_postgresql_conf()
{
	echo "set_primary_postgresql_conf ..."

	PG_CONF=$TEST_DIR/data-primary/postgresql.conf
	PG_HBA_CONF_0=$TEST_DIR/data-primary/pg_hba.conf
	PORT=`expr $BASE_PORT + 0`

	echo "listen_addresses = '*'" >> $PG_CONF
	echo "port = $PORT" >> $PG_CONF

	echo "archive_mode = on" >> $PG_CONF
	echo "archive_command = 'cp %p $TEST_DIR/archivedir/%f </dev/null'" >> $PG_CONF
	mkdir $TEST_DIR/archivedir

	echo "max_wal_senders = 10" >> $PG_CONF
	echo "max_replication_slots = 10" >> $PG_CONF

	echo "wal_level = replica" >> $PG_CONF
	echo "wal_keep_segments = 512" >> $PG_CONF

	echo "done"
}

function create_role()
{
	echo "create_role ..."

	PORT=`expr $BASE_PORT + 0`
	$PG_INSTALL_PATH/bin/psql  -h $HOST_IP -p $PORT -U $PG_USER -d postgres -c "CREATE ROLE $PG_REPLICATION_USER REPLICATION LOGIN"

	echo "done"
}

function create_standby()
{
	echo "create_standby ..."

	CLUSTER_DIR=$TEST_DIR/data-standby
	PG_CONF=$CLUSTER_DIR/postgresql.conf
	PORT_PRIMARY=`expr $BASE_PORT + 0`
	PORT_STANDBY=`expr $BASE_PORT + 1`

	$PG_INSTALL_PATH/bin/pg_basebackup -h $HOST_IP -p $PORT_PRIMARY -U $PG_REPLICATION_USER -Fp -Xs -Pv -R -D $CLUSTER_DIR

	echo "port = $PORT_STANDBY" >> $PG_CONF

	if [ $PG_VERSION -lt 120 ];then
		# PG_VERSION < 12.0
		sed -i "s/primary_conninfo = '/primary_conninfo = 'application_name=standby01 /g" $CLUSTER_DIR/recovery.conf
	else
		# PG_VERSION >= 12.0
		sed -i "s/primary_conninfo = '/primary_conninfo = 'application_name=standby01 /g" $CLUSTER_DIR/postgresql.auto.conf
	fi

	echo "done"
}

function set_sync_primary_postgresql_conf()
{
	echo "set_sync_primary_postgresql_conf ..."

	CLUSTER_DIR=$TEST_DIR/data-primary
	PG_CONF=$CLUSTER_DIR/postgresql.conf

	echo "synchronous_commit = on" >> $PG_CONF
	echo "synchronous_standby_names = 'standby01'" >> $PG_CONF

	echo "done"
}

function start_primary()
{
	echo "start_primary ..."

	CLUSTER_DIR=$TEST_DIR/data-primary

	$PG_INSTALL_PATH/bin/pg_ctl -D $CLUSTER_DIR start

	echo "done"
}

function start_pg_all()
{
	echo "start_pg_all ..."

	CLUSTER_DIR_PRIMARY=$TEST_DIR/data-primary
	CLUSTER_DIR_STANDBY=$TEST_DIR/data-standby

	$PG_INSTALL_PATH/bin/pg_ctl -D $CLUSTER_DIR_PRIMARY restart
	sleep 1
	$PG_INSTALL_PATH/bin/pg_ctl -D $CLUSTER_DIR_STANDBY start
	sleep 1

	echo "done"
}

function stop_pg_all()
{
	echo "stop_pg_all ..."

	CLUSTER_DIR_PRIMARY=$TEST_DIR/data-primary
	CLUSTER_DIR_STANDBY=$TEST_DIR/data-standby

	$PG_INSTALL_PATH/bin/pg_ctl -D $CLUSTER_DIR_STANDBY stop
	sleep 1
	$PG_INSTALL_PATH/bin/pg_ctl -D $CLUSTER_DIR_PRIMARY stop
	sleep 1

	echo "done"
}

function create_streaming_replication()
{
	echo "create_streaming_replication ..."

	initdb_primary_cluster
	set_primary_postgresql_conf
	start_primary
	create_role
	create_standby
	set_sync_primary_postgresql_conf
	start_pg_all

	echo "done"
}

function set_pool_conf()
{
echo "set_pool_conf ..."

PORT_PRIMARY=`expr $BASE_PORT + 0`
PORT_STANDBY=`expr $BASE_PORT + 1`
PORT_POOL=`expr $BASE_PORT + 2`
PORT_PCP=`expr $BASE_PORT + 3`
TEST_DIR=$TEST_DIR

rm -fr $TEST_DIR/pgpool.conf
cp $POOL_INSTALL_PATH/etc/pgpool.conf.sample-stream $TEST_DIR/pgpool.conf

cat >> $TEST_DIR/pgpool.conf <<'EOF'
port = __PORT_POOL__
pcp_port = __PORT_PCP__

backend_hostname0 = '127.0.0.1'
backend_port0 = __PORT_PRIMARY__
backend_weight0 = 0

backend_hostname1 = '127.0.0.1'
backend_port1 = __PORT_STANDBY__
backend_weight1 = 1

log_per_node_statement = on

pid_file_name = '/__TEST_DIR__/pgpool.pid'
black_function_list = 'currval,lastval,nextval,setval,insert_tb_f_func'
disable_load_balance_on_write = 'dml_adaptive'
dml_adaptive_object_relationship_list= 'tb_t1:tb_t2,insert_tb_f_func():tb_f,tb_v:tb_v_view'

sr_check_period = 0
sr_check_user = '__PG_USER__'
health_check_user = '__PG_USER__'
EOF

/bin/sed -i \
	 -e "/__PORT_PRIMARY__/s@__PORT_PRIMARY__@$PORT_PRIMARY@" \
	 -e "/__PORT_STANDBY__/s@__PORT_STANDBY__@$PORT_STANDBY@" \
	 -e "/__PORT_POOL__/s@__PORT_POOL__@$PORT_POOL@" \
	 -e "/__PORT_PCP__/s@__PORT_PCP__@$PORT_PCP@" \
	 -e "/__TEST_DIR__/s@__TEST_DIR__@$TEST_DIR@" \
	 -e "/__PG_USER__/s@__PG_USER__@$PG_USER@" \
	$TEST_DIR/pgpool.conf

	echo "done"
}

function start_pool()
{
	echo "start_pool ..."

	rm -rf /tmp/.s.PGSQL.110*
	$POOL_INSTALL_PATH/bin/pgpool -D -n -f $TEST_DIR/pgpool.conf 2>&1 | cat > $TEST_DIR/pgpool.log &

	echo "start_pool done"
}

function stop_pool()
{
	echo "stop_pool ..."

	$POOL_INSTALL_PATH/bin/pgpool -D -n -f $TEST_DIR/pgpool.conf stop 2>&1 | cat >> $TEST_DIR/pgpool.log &
	rm -rf /tmp/.s.PGSQL.110*

	echo "done"
}

function test_dml_extended()
{
echo "test_dml_extended ..."

	PORT_PRIMARY=`expr $BASE_PORT + 0`
	PORT_POOL=`expr $BASE_PORT + 2`

	export LD_LIBRARY_PATH=$PG_INSTALL_PATH/lib:$LD_LIBRARY_PATH

	export PGPORT=$PORT_POOL
	export PGHOST=$HOST_IP
	export PGUSER=$PG_USER
	export PGDATABASE=postgres

	# Set up test data files
	specified_tests=disable-load-balance-dml.data

    if [ $# -gt 0 ];then
		test_data_files=`(cd $BASE_DIR/test_data_files;ls |grep $specified_tests)`
    else
		test_data_files=`(cd $BASE_DIR/test_data_files;ls)`
    fi

    for i in $test_data_files
    do
		echo -n "testing $i ... "

		# check if modification to pgpool.conf specified.
		d=/tmp/diff$$
		grep '^##' $BASE_DIR/test_data_files/$i > $d
		if [ -s $d ]
		then
			sed -e 's/^##//' $d >> $TEST_DIR/pgpool.conf
		fi
		rm -f $d

		start_pool
		sleep 5

		while :
		do
			$PG_INSTALL_PATH/bin/psql -d $PGDATABASE -h $PGHOST -p $PGPORT -U $PG_USER -c "select 1"
			if [ $? = 0 ]
			then
			break
			fi
			sleep 1
		done

		$PG_INSTALL_PATH/bin/psql -h $HOST_IP -p $PORT_POOL -U $PG_USER -d postgres -c "show pool_nodes;"

		timeout=30
		timeout $timeout $POOL_INSTALL_PATH/bin/pgproto -f $BASE_DIR/test_data_files/$i > $BASE_DIR/results/$i 2>&1

		if [ $? = 124 ]
		then
			echo "pgproto timeout."
			timeoutcnt=`expr $timeoutcnt + 1`
		else
			echo "pgproto done."
		fi
    done

echo "test_dml_extended done"
}

function check_test_data_result()
{
	echo "check test data result ..."

	sed -e 's/L [0-9]*/L xxx/g' $BASE_DIR/expected/$i > expected_tmp
	sed -e 's/L [0-9]*/L xxx/g' $BASE_DIR/results/$i > results_tmp

	cmp expected_tmp results_tmp

	if [ $? != 0 ]
	then
		echo "failed: please check the file \"$diffs\""
		echo "=== $i ===" >> $diffs
		diff -c expected_tmp results_tmp >> $diffs
		rm expected_tmp results_tmp
		exit 1
	fi

	rm expected_tmp results_tmp
}

function check_test_log_result()
{
	echo "check test log result ..."

	# echo "check logfile \"$LOG_FILE\""

	# check if dml adaptive worked
	fgrep "standby" $LOG_FILE |grep "true">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: load_balance_node is not standby.
		exit 1
	fi

	# echo "check logfile \"$TEST_DIR/pgpool.log\""

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_dml_insert" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_dml_insert\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_dml_insert" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_dml_insert\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_dml_update" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_dml_update\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_dml_update" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_dml_update\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_dml_delete" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_dml_delete\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_dml_delete" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_dml_delete\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_t2" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_t2\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_t2" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_t2\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_f" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_f\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_f" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_f\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Parse: SELECT * FROM tb_v_view" $TEST_DIR/pgpool.log |grep "DB node id: 1">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Parse: SELECT * FROM tb_v_view\"" is no sent to standby node.
		exit 1
	fi

	fgrep "Bind: SELECT * FROM tb_v_view" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? != 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT * FROM tb_v_view\"" is no sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	fgrep "Bind: SELECT 1" $TEST_DIR/pgpool.log |grep "DB node id: 0">/dev/null 2>&1
	if [ $? == 0 ];then
	# expected result not found
		echo failed: "\"Bind: SELECT 1\"" should not be sent to primary node.
		exit 1
	fi

	# ---------------------------------------------------------------------------------------------------------------------

	echo "success: dml extended query test pass."
}

function install_temp_pgpool
{
	echo "creating pgpool-II temporary installation ..."

	POOL_INSTALL_PATH=$TEST_DIR/pgpool_temp_installed

	test -d $POOL_INSTALL_PATH || mkdir $POOL_INSTALL_PATH

	make install -C $BASE_DIR/../../../ -e prefix=${POOL_INSTALL_PATH} > ${POOL_INSTALL_PATH}/install.log 2>&1

	if [ $? != 0 ];then
	    echo "pgpool make install failed"
	    exit 1
	fi

	echo "done"
}

function run_test()
{
	echo "run_test ..."

	install_temp_pgpool
	create_streaming_replication

	set_pool_conf

	test_dml_extended

	stop_pool
	stop_pg_all

	echo "run_test done"
}

function print_usage
{
	printf "Usage:\n"
	printf "  %s [Options]...\n" $(basename $0) >&2
	printf "\nOptions:\n"
	printf "  -p   DIRECTORY           Postgres installed directory\n" >&2
	printf "  -h                       print this help and then exit\n\n" >&2
}

function init_environment()
{

	# clear last test dir
	rm -rf $BASE_DIR/results
    diffs=$BASE_DIR/diffs
    rm -f $diffs
	rm -rf $TEST_DIR
	rm -f $LOG_FILE

	# exit

	# create this test dir
	test ! -d $BASE_DIR/results && mkdir $BASE_DIR/results
	mkdir $TEST_DIR
}

function main
{
	check_version

	echo "running test ..."

	init_environment
	run_test > $LOG_FILE 2>&1

	echo "test done."

	set +e
	check_test_data_result && check_test_log_result
}

# ------------------------------------------- main --------------------------------------------

while getopts "p:h" OPTION
do
case $OPTION in
	p)  PG_INSTALL_PATH="$OPTARG";;
	h)  print_usage
		exit 2;;
esac
done

main