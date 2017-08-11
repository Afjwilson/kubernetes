#!/bin/bash 
# Assumptions:
# - docker, minikube and kubectl are already installed

declare ROOT_KEY=Cyberark1
declare CONJUR_CLUSTER_ACCT=dev
declare CONJUR_MASTER_DNS_NAME=conjur-master

# sudo not required for mac, but is for linux
DOCKER="docker"
if [[ "$(uname -s)" == "Linux" ]]; then
	DOCKER="sudo docker"
fi

##############################
##############################
# MAIN - takes no command line arguments

main() {
	startup_env
	startup_conjur_service
	configure_conjur_cluster

	CLUSTER_IP=$(kubectl describe svc conjur-master | awk '/IP:/ { print $2; exit}')
	EXTERNAL_IP=$(kubectl describe svc conjur-master | awk '/External IPs:/ { print $3; exit}')

	printf "\n\nIn conjur-client container, add:\n\t%s\tconjur-service\n to /etc/hosts.\n\n" $CLUSTER_IP
	printf "\n\nOutside the cluster, add:\n\t%s\tconjur-service\n to /etc/hosts.\n\n" $EXTERNAL_IP 
}

##############################
##############################

##############################
# STEP 1 - startup environment
startup_env() {
	# use the minikube docker environment
	eval $(minikube docker-env)
}

##############################
# STEP 2 - start service and label pods w/ roles
startup_conjur_service() {
	# start up conjur services from directory of yaml
	kubectl create -f conjur-service/

	# give containers time to get running
	sleep 5
	# tag with initial roles in cluster
	kubectl label --overwrite pods conjur-onyx-0 app=conjur-master
	kubectl label --overwrite statefulSet conjur-onyx app=conjur-master
	kubectl label --overwrite pods conjur-jade-0 app=sync-conjur-standby
	kubectl label --overwrite statefulSet conjur-jade app=sync-conjur-standby
	kubectl label --overwrite pods conjur-quartz-0 app=async-conjur-standby
	kubectl label --overwrite statefulSet conjur-quartz app=async-conjur-standby

}

##############################
# STEP 3 - configure cluster based on role labels
# Input: none
configure_conjur_cluster() {
	# get name of stateful set that is labeled conjur-master
	local MASTER_SET=$(kubectl get statefulSet \
				-l app=conjur-master --no-headers \
				| awk '{ print $1 }' )
	local MASTER_POD_NAME=$MASTER_SET-0
	local MASTER_POD_IP=$(kubectl describe pod $MASTER_POD_NAME | awk '/IP:/ { print $2 }')

	# configure Conjur master server using evoke
	kubectl cp conjur.json $MASTER_POD_NAME:/etc/conjur.json
	kubectl exec -it $MASTER_POD_NAME -- evoke configure master -j /etc/conjur.json -h $CONJUR_MASTER_DNS_NAME -p $ROOT_KEY $CONJUR_CLUSTER_ACCT

	# prepare seed files for standbys and followers
	kubectl exec -it $MASTER_POD_NAME -- bash -c "evoke seed standby > /tmp/standby-seed.tar"
	kubectl cp $MASTER_POD_NAME:/tmp/standby-seed.tar ./standby-seed.tar
	kubectl exec -it $MASTER_POD_NAME -- bash -c "evoke seed follower $CONJUR_MASTER_DNS_NAME > /tmp/follower-seed.tar"
	kubectl cp $MASTER_POD_NAME:/tmp/follower-seed.tar ./follower-seed.tar


	# get name of statefulSet that is labeled sync standby
	local SYNC_STANDBY_SET=$(kubectl get statefulSet \
				-l app=sync-conjur-standby --no-headers \
				| awk '{ print $1 }' )
	local SYNC_STANDBY_POD_NAME=$SYNC_STANDBY_SET-0
	# copy seed file to sync standby, unpack and configure
	kubectl cp conjur.json $SYNC_STANDBY_POD_NAME:/etc/conjur.json
	kubectl cp ./standby-seed.tar $SYNC_STANDBY_POD_NAME:/tmp/standby-seed.tar
	kubectl exec -it $SYNC_STANDBY_POD_NAME -- bash -c "evoke unpack seed /tmp/standby-seed.tar"
	kubectl exec -it $SYNC_STANDBY_POD_NAME -- evoke configure standby -j /etc/conjur.json -i $MASTER_POD_IP
	# enable synchronous replication
	kubectl exec -it $MASTER_POD_NAME -- bash -c "evoke replication sync --force"

	# get name of statefulSet that is labeled async standby
	local ASYNC_STANDBY_SET=$(kubectl get statefulSet \
				-l app=async-conjur-standby --no-headers \
				| awk '{ print $1 }' )
	local ASYNC_STANDBY_POD_NAME=$ASYNC_STANDBY_SET-0
	# copy seed file to async standby, unpack and configure
	kubectl cp conjur.json $ASYNC_STANDBY_POD_NAME:/etc/conjur.json
	kubectl cp ./standby-seed.tar $ASYNC_STANDBY_POD_NAME:/tmp/standby-seed.tar
	kubectl exec -it $ASYNC_STANDBY_POD_NAME -- bash -c "evoke unpack seed /tmp/standby-seed.tar"
	kubectl exec -it $ASYNC_STANDBY_POD_NAME -- evoke configure standby -j /etc/conjur.json -i $MASTER_POD_IP
}

main $@
