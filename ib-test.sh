#!/bin/bash

export START_PHASE=${START_PHASE:-0}
export END_PHASE=${END_PHASE:-999}
export MPI_FLAVOURS=${MPI_FLAVOURS:-"mvapich2 mpich openmpi openmpi2"}
source $(dirname $0)/helpers/common.sh
load_helpers $(dirname $0) "ib"

if [ $# -ne 2 ]; then
	fatal_error "Usage $0 host1 host2" >&2
fi
export HOST1=$1
export HOST2=$2
export IP1=192.168.0.1
export IP2=192.168.0.2

#########################
#
# Phase 0: State cleanup
# - Install required packages
# - Reset everything needed to mimic an after-reboot run
#
#########################
phase_0(){
	juLog_fatal -name=h1_setup_requirements "setup_requirements $HOST1"
	juLog_fatal -name=h2_setup_requirements "setup_requirements $HOST2"

	juLog -name=h1_kill_opensm "kill_opensm $HOST1"
	juLog -name=h2_kill_opensm "kill_opensm $HOST2"

	juLog -name=h1_reset_all_ports "reset_all_ports $HOST1"
	juLog -name=h2_reset_all_ports "reset_all_ports $HOST2"
}
run_phase 0 phase_0 "State Cleanup"

#########################
#
# Phase 1: Fabric init
# - Start demons (opensm, rdma-ndd)
# - SSH known key setup to as some tests will fail if
#   hosts do not know each other
# - Device status check
#
#########################
phase_1_1(){
	juLog -name=h1_rdma_ndd "setup_rdma_ndd $HOST1"
	juLog -name=h2_rdma_ndd "setup_rdma_ndd $HOST2"

	# We need to sleep a little bit here in case the port are stil reseting from pahse 0
	sleep 1
	juLog_fatal -name=h1_openSM_start "start_opensm $HOST1"
	# Leave some time for openSM to bring the link up
	sleep 3
}
run_phase 1 phase_1_1 "Fabric init (1/2)"

# Do not wrap these as they export needed variables
get_port $HOST1 1
get_port $HOST2 2

phase_1_2(){
	juLog_fatal -name=h1_ip_setup   "set_ipoib_down $HOST1 $IPPORT1; set_ipoib_up $HOST1 $IPPORT1 $IP1/24"
	juLog_fatal -name=h2_ip_setup   "set_ipoib_down $HOST2 $IPPORT2; set_ipoib_up $HOST2 $IPPORT2 $IP2/24"
	juLog_fatal -name=h1_setup_ssh_keys "setup_ssh $HOST1 $IP2"
	juLog_fatal -name=h2_setup_ssh_keys "setup_ssh $HOST2 $IP1"

	juLog_fatal -name=h1_ibvinfo tp $HOST1 ibv_devinfo
	juLog_fatal -name=h2_ibvinfo tp $HOST2 ibv_devinfo

	juLog_fatal -name=h1_ibdiagnet test_ibdiagnet $HOST1
	juLog_fatal -name=h2_ibdiagnet test_ibdiagnet $HOST2

	juLog -name=h1_test_nodedesc "test_nodedesc $HOST1 $GUID1"
	juLog -name=h2_test_nodedesc "test_nodedesc $HOST2 $GUID2"
}
run_phase 1 phase_1_2 "Fabric init (2/2)"

#########################
#
# Phase 2: IPoIB
#
#########################
phase_2(){
	for mode in connected datagram; do
		juLog_fatal -name=h1_${mode}_ip_mode "set_ipoib_mode $HOST1 $IPPORT1 $mode"
		juLog_fatal -name=h1_${mode}_ip_down "set_ipoib_down $HOST1 $IPPORT1"
		juLog_fatal -name=h1_${mode}_ip_up   "set_ipoib_up $HOST1 $IPPORT1 $IP1/24"

		juLog_fatal -name=h2_${mode}_ip_mode "set_ipoib_mode $HOST2 $IPPORT2 $mode"
		juLog_fatal -name=h2_${mode}_ip_down "set_ipoib_down $HOST2 $IPPORT2"
		juLog_fatal -name=h2_${mode}_ip_up   "set_ipoib_up $HOST2 $IPPORT2 $IP2/24"

		for size in 511 1025 2044 8192 32768 65492; do
			juLog -name=h1_${mode}_ping_$size "test_ping $HOST1 $IP2 $size"
			juLog -name=h2_${mode}_ping_$size "test_ping $HOST2 $IP1 $size"
		done

		# TODO: Add ping tests that are expected to fail

		juLog -name=h1_${mode}_sftp "test_sftp $HOST1 $IP2"
		juLog -name=h1_${mode}_sftp "test_sftp $HOST1 $IP2"
	done
}
run_phase 2 phase_2 "IPoIB"

#########################
#
# Phase 3: SM Failover
#
#########################
phase_3(){
	juLog -name=test_sm_failover "test_sm_failover $HOST1 $LID1 $HOST2 $LID2"
}
run_phase 3 phase_3 "SM Failover"

#########################
#
# Phase 4: SRP
#
#########################
phase_4(){
	juLog -name=ibsrpdm tp $HOST1 '/usr/sbin/ibsrpdm'
}
run_phase 4 phase_4 "SRP"

#########################
#
# Phase 5: NFSoRDMA
#
#########################
phase_5(){
	juLog -name=nfs_over_rdma test_nfs $HOST1 $IP1 $HOST2
}
run_phase 5 phase_5 "NFSoRDMA"

#########################
#
# Phase 6: DAPL
#
#########################
phase_6(){
	true
}
run_phase 6 phase_6 "DAPL"

#########################
#
# Phase 7: RDMA/Verbs
#
#########################
phase_7(){
	for mode in rc uc ud srq; do
		juLog -name=${mode}_pingpong "(
	  	  test_ibv_pingpong ibv_${mode}_pingpong $HOST1 $HCA1 $IBPORT1 $HOST2 $HCA2 $IBPORT2 &&
	  	  test_ibv_pingpong ibv_${mode}_pingpong $HOST2 $HCA2 $IBPORT2 $HOST1 $HCA1 $IBPORT1
        )"
	done
}
run_phase 7 phase_7 "RDMA/Verbs"

#########################
#
# Phase 8: MPI
#
#########################
phase_8(){
	for flavour in $MPI_FLAVOURS; do
		juLog -name=mpitests_${flavour} test_mpi ${flavour} $HOST1 $IP1 $IP2
	done
}
run_phase 8 phase_8 "MPI"

#########################
#
# Phase 9: libfabric
#
#########################
phase_9(){
	juLog -name=fabtests test_libfabric $HOST1 $IP1 $IP2
}
run_phase 9 phase_9 "libfabric"

