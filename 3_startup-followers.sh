#!/bin/bash -e

set -o pipefail

# Configures followers

declare CONFIG_DIR=conjur-service

main() {
	configure_followers
}

########################
# Create and configure the followers

configure_followers() {
	kubectl create -f $CONFIG_DIR/conjur-follower.yaml
	sleep 5

	# get list of the other pods 
	pod_list=$(kubectl get pods -lapp=conjur-follower \
			| awk '/conjur-follower/ {print $1}')
	for pod_name in $pod_list; do
		# configure follower
		kubectl cp $CONFIG_DIR/follower-seed.tar $pod_name:/tmp/follower-seed.tar
		kubectl exec $pod_name evoke unpack seed /tmp/follower-seed.tar
		kubectl exec $pod_name -- evoke configure follower -j /etc/conjur.json
	done
}

main $@
