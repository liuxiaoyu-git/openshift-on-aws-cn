#!/bin/bash -xe

source ${P}

if [ -f /quickstart/pre-install.sh ]
then
  /quickstart/pre-install.sh
fi

qs_enable_epel &> /var/log/userdata.qs_enable_epel.log

if [ -z ${LOCAL_REPO_HOST_IP} ]; then 
  qs_retry_command 25 aws s3 cp ${QS_S3URI}scripts/redhat_ose-register-${OCP_VERSION}.sh ~/redhat_ose-register.sh
  chmod 755 ~/redhat_ose-register.sh
  qs_retry_command 25 ~/redhat_ose-register.sh ${RH_USER} ${RH_PASS} ${RH_POOLID}
else 
  qs_retry_command 25 aws s3 cp ${QS_S3URI}scripts/yum.repos.d/ose.repo /etc/yum.repos.d/ose.repo
  sed -ie "s/<server_IP>/${LOCAL_REPO_HOST_IP}/g" /etc/yum.repos.d/ose.repo
  rm /etc/yum.repos.d/ose.repoe
  curl -o /etc/yum.repos.d/epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
  rm -fr /var/cache/yum/*
  yum clean all
fi

qs_retry_command 10 yum -y install ansible-2.4.6.0 yum-versionlock
sed -i 's/#host_key_checking = False/host_key_checking = False/g' /etc/ansible/ansible.cfg
yum versionlock add ansible
yum repolist -v | grep 'OpenShift\|ose'

qs_retry_command 10 pip install boto3 -i https://pypi.douban.com/simple &> /var/log/userdata.boto3_install.log
mkdir -p /root/ose_scaling/aws_openshift_quickstart
mkdir -p /root/ose_scaling/bin
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/__init__.py /root/ose_scaling/aws_openshift_quickstart/__init__.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/logger.py /root/ose_scaling/aws_openshift_quickstart/logger.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/scaler.py /root/ose_scaling/aws_openshift_quickstart/scaler.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/utils.py /root/ose_scaling/aws_openshift_quickstart/utils.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/bin/aws-ose-qs-scale /root/ose_scaling/bin/aws-ose-qs-scale
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/setup.py /root/ose_scaling/setup.py
if [ "${OCP_VERSION}" == "3.9" ] ; then
    qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/predefined_openshift_vars.txt /tmp/openshift_inventory_predefined_vars
else
    qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/predefined_openshift_vars_3.10.txt /tmp/openshift_inventory_predefined_vars
fi
pip install /root/ose_scaling

qs_retry_command 10 cfn-init -v --stack ${AWS_STACKNAME} --resource AnsibleConfigServer --configsets cfg_node_keys --region ${AWS_REGION}

echo openshift_master_cluster_hostname=${INTERNAL_MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_cluster_public_hostname=${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars

# if [ -z ${BASE_DOMAIN_NAME} ]; then 
#     echo openshift_master_cluster_public_hostname=${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars
# else 
#     echo openshift_master_cluster_public_hostname=${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
# fi

# disable docker image availability check. workaround for the hardcoded 10 seconds time out
echo 'openshift_disable_check="docker_image_availability"' >> /tmp/openshift_inventory_userdata_vars

echo openshift_master_default_subdomain=${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars

# if [ -z ${BASE_DOMAIN_NAME} ]; then 
#     echo openshift_master_default_subdomain=${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars
# else
#     if [ "$(echo ${MASTER_ELBDNSNAME} | grep -c '\.elb\.${AWS_REGION}\.amazonaws\.com\.cn')" == "0" ] ; then
#         echo openshift_master_default_subdomain=${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars
#     fi
# fi

if [ "${ENABLE_HAWKULAR}" == "True" ] ; then

    echo openshift_metrics_hawkular_hostname=metrics.${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars

    # if [ -z ${BASE_DOMAIN_NAME} ]; then
    #     echo openshift_metrics_hawkular_hostname=metrics.${BASE_DOMAIN_NAME} >> /tmp/openshift_inventory_userdata_vars
    # else 
    #     if [ "$(echo ${MASTER_ELBDNSNAME} | grep -c '\.elb\.${AWS_REGION}\.amazonaws\.com\.cn')" == "0" ] ; then
    #         echo openshift_metrics_hawkular_hostname=metrics.${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
    #     else
    #         echo openshift_metrics_hawkular_hostname=metrics.router.default.svc.cluster.local >> /tmp/openshift_inventory_userdata_vars
    #     fi
    # fi

    echo openshift_metrics_install_metrics=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_start_cluster=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_cassandra_storage_type=dynamic >> /tmp/openshift_inventory_userdata_vars
fi

if [ "${ENABLE_AUTOMATIONBROKER}" == "Disabled" ] ; then
    echo ansible_service_broker_install=false >> /tmp/openshift_inventory_userdata_vars
fi

if [ "${OCP_VERSION}" != "3.9" ] ; then
    echo openshift_hosted_registry_storage_s3_bucket=${REGISTRY_BUCKET} >> /tmp/openshift_inventory_userdata_vars
    echo openshift_hosted_registry_storage_s3_region=${AWS_REGION} >> /tmp/openshift_inventory_userdata_vars
    echo openshift_hosted_registry_storage_s3_regionendpoint=${S3_ENDPOINT} >> /tmp/openshift_inventory_userdata_vars
fi

echo openshift_master_api_port=443 >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_console_port=443 >> /tmp/openshift_inventory_userdata_vars

echo openshift_docker_options=' --selinux-enabled --log-opt max-size=1M --log-opt max-file=3 --log-driver=json-file --insecure-registry 172.30.0.0/16 --signature-verification=false --registry-mirror=https://dockerhub.awsguru.cc' >> /tmp/openshift_inventory_userdata_vars

qs_retry_command 10 yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
# Workaround this not-a-bug https://bugzilla.redhat.com/show_bug.cgi?id=1187057
pip uninstall -y urllib3
qs_retry_command 10 yum -y update
qs_retry_command 10 pip install urllib3 -i https://pypi.douban.com/simple
if [ "${OCP_VERSION}" == "3.9" ] ; then
    qs_retry_command 10 yum -y install atomic-openshift-utils
fi
qs_retry_command 10 yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder

cd /tmp
qs_retry_command 10 wget https://aws-quickstart-cn.s3.cn-northwest-1.amazonaws.com.cn/aws-ssm-agent/amazon-ssm-agent.rpm
qs_retry_command 10 yum install -y ./amazon-ssm-agent.rpm
systemctl start amazon-ssm-agent
systemctl enable amazon-ssm-agent
rm ./amazon-ssm-agent.rpm
cd -

if [ "${GET_ANSIBLE_FROM_GIT}" == "True" ]; then
  CURRENT_PLAYBOOK_VERSION=https://github.com/openshift/openshift-ansible/archive/openshift-ansible-${OCP_ANSIBLE_RELEASE}.tar.gz
  curl  --retry 5  -Ls ${CURRENT_PLAYBOOK_VERSION} -o openshift-ansible.tar.gz
  tar -zxf openshift-ansible.tar.gz
  rm -rf /usr/share/ansible
  mkdir -p /usr/share/ansible
  mv openshift-ansible-* /usr/share/ansible/openshift-ansible
else
  qs_retry_command 10 yum -y install openshift-ansible
fi

qs_retry_command 10 yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude

qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaleup_wrapper.yml  /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/bootstrap_wrapper.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/post_scaledown.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/post_scaleup.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/pre_scaleup.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/pre_scaledown.yml /usr/share/ansible/openshift-ansible/
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/playbooks/remove_node_from_etcd_cluster.yml /usr/share/ansible/openshift-ansible/
while [ $(aws cloudformation describe-stack-events --stack-name ${AWS_STACKNAME} --region ${AWS_REGION} --query 'StackEvents[?ResourceStatus == `CREATE_COMPLETE` && ResourceType == `AWS::AutoScaling::AutoScalingGroup`].LogicalResourceId' --output json | grep -c 'OpenShift') -lt 3 ] ; do
    echo "Waiting for ASG's to complete provisioning..."
    sleep 120
done

export OPENSHIFTMASTERASG=$(aws cloudformation describe-stack-resources --stack-name ${AWS_STACKNAME} --region ${AWS_REGION} --query 'StackResources[? ResourceStatus == `CREATE_COMPLETE` && LogicalResourceId == `OpenShiftMasterASG`].PhysicalResourceId' --output text)

qs_retry_command 10 aws autoscaling suspend-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}
qs_retry_command 10 aws autoscaling attach-load-balancer-target-groups --auto-scaling-group-name ${OPENSHIFTMASTERASG} --target-group-arns ${OPENSHIFTMASTERINTERNALTGARN} --region ${AWS_REGION}

/bin/aws-ose-qs-scale --generate-initial-inventory --ocp-version ${OCP_VERSION} --write-hosts-to-tempfiles --debug
cat /tmp/openshift_ansible_inventory* >> /tmp/openshift_inventory_userdata_vars || true
sed -i 's/#pipelining = False/pipelining = True/g' /etc/ansible/ansible.cfg
sed -i 's/#log_path/log_path/g' /etc/ansible/ansible.cfg
sed -i 's/#stdout_callback.*/stdout_callback = json/g' /etc/ansible/ansible.cfg
sed -i 's/#deprecation_warnings = True/deprecation_warnings = False/g' /etc/ansible/ansible.cfg

qs_retry_command 50 ansible -m ping all

ansible-playbook /usr/share/ansible/openshift-ansible/bootstrap_wrapper.yml > /var/log/bootstrap.log
ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml >> /var/log/bootstrap.log
ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml >> /var/log/bootstrap.log

ansible masters -a "htpasswd -b /etc/origin/master/htpasswd admin ${OCP_PASS}"
aws autoscaling resume-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}

qs_retry_command 10 yum install -y atomic-openshift-clients
AWSSB_SETUP_HOST=$(head -n 1 /tmp/openshift_initial_masters)
mkdir -p ~/.kube/
scp $AWSSB_SETUP_HOST:~/.kube/config ~/.kube/config

if [ "${ENABLE_AWSSB}" == "Enabled" ]; then
    mkdir -p ~/aws_broker_install
    cd ~/aws_broker_install
    qs_retry_command 10 wget https://awsservicebroker.s3.cn-northwest-1.amazonaws.com.cn/scripts/release-${SB_VERSION}/packaging/openshift/deploy.sh
    qs_retry_command 10 wget https://awsservicebroker.s3.cn-northwest-1.amazonaws.com.cn/scripts/release-${SB_VERSION}/packaging/openshift/aws-servicebroker.yaml
    qs_retry_command 10 wget https://awsservicebroker.s3.cn-northwest-1.amazonaws.com.cn/scripts/release-${SB_VERSION}/packaging/openshift/parameters.env
    chmod +x deploy.sh
    sed -i "s/TABLENAME=awssb/TABLENAME=${SB_TABLE}/" parameters.env
    sed -i "s/TARGETACCOUNTID=/TARGETACCOUNTID=${SB_ACCOUNTID}/" parameters.env
    sed -i "s/TARGETROLENAME=/TARGETROLENAME=${SB_ROLE}/" parameters.env
    sed -i "s/VPCID=/VPCID=${VPCID}/" parameters.env
    sed -i "s/^REGION=us-east-1$/REGION=${AWS_REGION}/" parameters.env
    sed -i "s/^S3REGION=us-east-1$/S3REGION=${AWS_REGION}/" parameters.env
    sed -i "s/^IMAGE=awsservicebroker\/aws-servicebroker:beta$/IMAGE=awsguru\/aws-servicebroker:beta/" parameters.env
    sed -i "s/^S3KEY=templates\/latest$/S3KEY=templates\/1.0.0-beta/" parameters.env
    export KUBECONFIG=/root/.kube/config
    ./deploy.sh
    cd ../
    rm -rf ./aws_broker_install/
fi

rm -rf /tmp/openshift_initial_*

if [ -f /quickstart/post-install.sh ]
then
  /quickstart/post-install.sh
fi