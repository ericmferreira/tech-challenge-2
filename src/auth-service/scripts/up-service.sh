#!/bin/bash
echo "Starting K8s Auth Service Application"

echo "Creating Persistent Volume Claim for PostgreSQL Auth Service"
kubectl apply -f ../k8s/pvc-psql-auth-service.yaml

echo "Creating Secrets, ConfigMaps, Deployments, Services and Ingress for Auth Service"
kubectl apply -f ../k8s/secrets-k8s-auth-service.yaml

kubectl apply -f ../k8s/configmap-go-auth-service.yaml

kubectl apply -f ../k8s/configmap-psql-auth-service.yaml

kubectl apply -f ../k8s/deployment-psql-auth-service.yaml

kubectl apply -f ../k8s/deployment-go-auth-service.yaml

kubectl apply -f ../k8s/service-psql-auth-service.yaml

kubectl apply -f ../k8s/service-go-auth-service.yaml

kubectl apply -f ../k8s/ingress-go-auth-service.yaml

