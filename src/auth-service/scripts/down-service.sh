#!/bin/bash

echo "Stopping K8s Auth Service Application"

echo "Deleting Deployments"
kubectl delete deployments deployment-go-auth-service deployment-psql-auth-service

echo "Deleting Services"
kubectl delete services service-go-auth-service service-psql-auth-service

echo "Deleting Ingress"
kubectl delete ingress ingress-go-auth-service

echo "Deleting ConfigMaps"
kubectl delete configmaps configmap-go-auth-service configmap-psql-auth-service

echo "Deleting Secrets"
kubectl delete secrets secret-k8s-auth-service