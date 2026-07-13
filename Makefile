KUBECONFIG_FLAG := --kubeconfig=minikube/kubeconfig

.PHONY: minikube frr-node clean
minikube:
	docker compose --project-directory minikube -f minikube/docker-compose.yml up -d --build
	docker exec minikube cat /var/lib/minikube/host.kubeconfig > minikube/kubeconfig
	$(MAKE) frr-node

# helm-delivered (not baked into the image like /addons): applies retroactively to a
# running cluster, so BGP knobs (ASN, timers, ToR convention) iterate without a rebuild.
frr-node:
	@until kubectl $(KUBECONFIG_FLAG) get --raw=/healthz >/dev/null 2>&1; do echo "waiting for apiserver..."; sleep 2; done
	@# healthz isn't enough: the host kubeconfig's cluster-admin binding is itself an addon
	@# (apply-addons oneshot) — helm needs it to read its release secrets
	@until kubectl $(KUBECONFIG_FLAG) auth can-i '*' '*' >/dev/null 2>&1; do echo "waiting for cluster-admin RBAC..."; sleep 2; done
	helm upgrade --install frr-node charts/frr-node --namespace kube-system $(KUBECONFIG_FLAG)

clean:
	docker compose --project-directory minikube -f minikube/docker-compose.yml down -v --remove-orphans
