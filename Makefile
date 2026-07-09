.PHONY: kind minikube clean
kind:
	docker compose --project-directory kind -f kind/docker-compose.yml up -d

minikube:
	docker compose --project-directory minikube -f minikube/docker-compose.yml up -d --build
	docker exec minikube cat /var/lib/minikube/host.kubeconfig > minikube/kubeconfig

clean:
	docker compose --project-directory kind -f kind/docker-compose.yml down -v --remove-orphans
	docker compose --project-directory minikube -f minikube/docker-compose.yml down -v --remove-orphans
