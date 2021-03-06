#!/usr/bin/env bash

[ "${1}" == "--help" ] && echo ./update-instance.sh '<INSTANCE_ID>' && exit 0

source functions.sh
! cluster_management_init "${1}" && exit 1

! [ -e "${CKAN_VALUES_FILE}" ] && echo missing ${CKAN_VALUES_FILE} && exit 1

echo Creating instance: ${INSTANCE_ID}

INSTANCE_DOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("domain", ""))
' 2>/dev/null`

CKAN_ADMIN_EMAIL=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanAdminEmail", "admin@${INSTANCE_ID}"))
'`

WITH_SANS_SSL=`python3 -c '
import yaml;
print("1" if yaml.load(open("'${CKAN_VALUES_FILE}'")).get("withSansSSL", False) else "0")
' 2>/dev/null`

REGISTER_SUBDOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("registerSubdomain", ""))
' 2>/dev/null`

CKAN_HELM_CHART_REPO=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanHelmChartRepo", "https://raw.githubusercontent.com/ViderumGlobal/ckan-cloud-helm/master/charts_repository"))
' 2>/dev/null`

CKAN_HELM_CHART_VERSION=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanHelmChartVersion", ""))
' 2>/dev/null`

LOAD_BALANCER_HOSTNAME=$(kubectl $KUBECTL_GLOBAL_ARGS -n default get service traefik -o yaml \
    | python3 -c 'import sys, yaml; print(yaml.load(sys.stdin)["status"]["loadBalancer"]["ingress"][0]["hostname"])' 2>/dev/null)

if [ "${REGISTER_SUBDOMAIN}" != "" ]; then
    cluster_register_sub_domain "${REGISTER_SUBDOMAIN}" "${LOAD_BALANCER_HOSTNAME}"
    [ "$?" != "0" ] && exit 1
fi

if ! [ -z "${INSTANCE_DOMAIN}" ]; then
    ! add_domain_to_traefik "${INSTANCE_DOMAIN}" "${WITH_SANS_SSL}" "${INSTANCE_ID}" && exit 1
fi

if kubectl $KUBECTL_GLOBAL_ARGS get ns "${INSTANCE_NAMESPACE}"; then
    IS_NEW_NAMESPACE=0
    echo Namespace exists: ${INSTANCE_NAMESPACE}
    echo skipping RBAC creation
else
    IS_NEW_NAMESPACE=1
    echo Creating namespace: ${INSTANCE_NAMESPACE}

    kubectl $KUBECTL_GLOBAL_ARGS create ns "${INSTANCE_NAMESPACE}" &&\
    kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" \
        create serviceaccount "ckan-${INSTANCE_NAMESPACE}-operator" &&\
    kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" \
        create role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                    --verb list,get,create \
                    --resource secrets,pods,pods/exec,pods/portforward &&\
    kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" \
        create rolebinding "ckan-${INSTANCE_NAMESPACE}-operator-rolebinding" \
                           --role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                           --serviceaccount "${INSTANCE_NAMESPACE}:ckan-${INSTANCE_NAMESPACE}-operator"
    [ "$?" != "0" ] && exit 1
fi

echo Deploying CKAN instance: ${INSTSANCE_ID}

echo Initializing ckan-cloud Helm repo "${CKAN_HELM_CHART_REPO}"
helm init --client-only &&\
helm repo add ckan-cloud "${CKAN_HELM_CHART_REPO}"
[ "$?" != "0" ] && exit 1

helm_upgrade() {
    if [ -z "${CKAN_HELM_CHART_VERSION}" ]; then
        echo Using latest stable ckan chart
        VERSIONARGS=""
    else
        echo Using ckan chart version ${CKAN_HELM_CHART_VERSION}
        VERSIONARGS=" --version ${CKAN_HELM_CHART_VERSION} "
    fi
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" ckan-cloud/ckan \
        -if "${CKAN_VALUES_FILE}" "$@" --dry-run --debug > /dev/stderr $VERSIONARGS &&\
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" ckan-cloud/ckan \
        -if "${CKAN_VALUES_FILE}" $VERSIONARGS "$@"
}

wait_for_pods() {
    DELAY_SECONDS=10
    TOTAL_SECONDS=0
    while ! kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" get pods -o yaml | python3 -c '
import yaml, sys;
for pod in yaml.load(sys.stdin)["items"]:
    if pod["status"]["phase"] != "Running":
        print(pod["metadata"]["name"] + ": " + pod["status"]["phase"])
        exit(1)
    elif not pod["status"]["containerStatuses"][0]["ready"]:
        print(pod["metadata"]["name"] + ": ckan container is not ready")
        exit(1)
exit(0)
    '; do
        kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" get pods
        sleep $DELAY_SECONDS
        TOTAL_SECONDS=$(expr $TOTAL_SECONDS + $DELAY_SECONDS)
        echo "...${TOTAL_SECONDS}s"
        # if [ "$(expr $TOTAL_SECONDS > 180)" == "1" ]; then
        #     echo "Waiting too long, deleting and redeploying ckan and jobs deployments"
        #     kubectl $KUBECTL_GLOBAL_ARGS delete deployment ckan jobs
        #     ! helm_upgrade && return 1
        # fi
    done &&\
    kubectl $KUBECTL_GLOBAL_ARGS --namespace "${INSTANCE_NAMESPACE}" get pods
}

if [ "${IS_NEW_NAMESPACE}" == "1" ]; then
    helm_upgrade --set replicas=1 --set nginxReplicas=1 &&\
    sleep 2 &&\
    wait_for_pods
    [ "$?" != "0" ] && exit 1
fi

helm_upgrade &&\
sleep 1 &&\
wait_for_pods
[ "$?" != "0" ] && exit 1

CKAN_POD_NAME=$(kubectl $KUBECTL_GLOBAL_ARGS -n ${INSTANCE_NAMESPACE} get pods -l "app=ckan" -o 'jsonpath={.items[0].metadata.name}')
echo CKAN_POD_NAME = "${CKAN_POD_NAME}" > /dev/stderr

if kubectl $KUBECTL_GLOBAL_ARGS -n ${INSTANCE_NAMESPACE} exec -it ${CKAN_POD_NAME} -- bash -c \
    "ckan-paster --plugin=ckan sysadmin -c /etc/ckan/production.ini list" \
        | grep "name=admin"
then
    CKAN_ADMIN_PASSWORD=$( \
        get_secret_from_json "$(kubectl $KUBECTL_GLOBAL_ARGS -n "${INSTANCE_NAMESPACE}" get secret ckan-admin-password -o json)" \
        "CKAN_ADMIN_PASSWORD" \
    )
    echo admin user already exists
else
    CKAN_ADMIN_PASSWORD=$(python3 -c "import binascii,os;print(binascii.hexlify(os.urandom(12)).decode())")
    ! kubectl $KUBECTL_GLOBAL_ARGS -n "${INSTANCE_NAMESPACE}" create secret generic ckan-admin-password "--from-literal=CKAN_ADMIN_PASSWORD=${CKAN_ADMIN_PASSWORD}" && exit 1
    echo y \
        | kubectl $KUBECTL_GLOBAL_ARGS -n ${INSTANCE_NAMESPACE} exec -it ${CKAN_POD_NAME} -- bash -c \
            "ckan-paster --plugin=ckan sysadmin -c /etc/ckan/production.ini add admin password=${CKAN_ADMIN_PASSWORD} email=${CKAN_ADMIN_EMAIL}" \
                > /dev/stderr
    [ "$?" != "0" ] && exit 1
fi

if ! [ -z "${INSTANCE_DOMAIN}" ]; then
    echo Running sanity tests for CKAN instance ${INSTSANCE_ID} on domain ${INSTANCE_DOMAIN}
    if [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]; then
        kubectl $KUBECTL_GLOBAL_ARGS -n default patch deployment traefik \
            -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"`date +'%s'`\"}}}}}" &&\
        kubectl $KUBECTL_GLOBAL_ARGS -n default rollout status deployment traefik &&\
        sleep 10 &&\
        [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]
        [ "$?" != "0" ] && exit 1
    fi
fi

echo Great Success!
echo CKAN Instance ${INSTANCE_ID} is ready
instance_connection_info "${INSTANCE_ID}" "${INSTANCE_NAMESPACE}" "${INSTANCE_DOMAIN}" "${CKAN_ADMIN_PASSWORD}"

exit 0
