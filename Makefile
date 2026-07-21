.PHONY: minikube clean
minikube:
	docker compose --project-directory minikube -f minikube/docker-compose.yml up -d --build
	docker exec minikube cat /var/lib/minikube/host.kubeconfig > minikube/kubeconfig

# NOTE: the AKS flex-node support (FRR Route-Server relay + CoreDNS + kube-proxy) lives in
# charts/flex-node-system and is deployed to a real cluster by hand (helm -f values-<cluster>.yaml),
# not from here. The docker lab's in-cluster route server was removed pending a rethink.

clean:
	docker compose --project-directory minikube -f minikube/docker-compose.yml down -v --remove-orphans
