.PHONY: minikube clean
minikube:
	docker compose --project-directory minikube -f minikube/docker-compose.yml up -d --build
	docker exec minikube cat /var/lib/minikube/host.kubeconfig > minikube/kubeconfig

# NOTE: the in-cluster route server / BGP for the docker lab was removed from
# charts/route-server pending a rethink; the chart is currently AKS-shaped and is
# deployed to a real cluster by hand (helm -f values-<cluster>.yaml), not from here.

clean:
	docker compose --project-directory minikube -f minikube/docker-compose.yml down -v --remove-orphans
