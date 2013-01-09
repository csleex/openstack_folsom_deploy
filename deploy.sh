#!/usr/bin/env bash
#
# OpenStack Folsom Install Script
#
# allright reserved by Tomokazu Hirai @jedipunkz
#
# This is a script for installation of OpenStack Folsom. You can choose nova-network or
# quantum. and you can execute this script on Ubuntu 12.04 or 12.10. Please README.md for
# more details.
#
# --------------------------------------------------------------------------------------
# Usage : sudo ./deploy.sh <node_type> <network_type>
#   node_type    : allinone | controller | network | compute | create_network
#   network_type : nova-network | quantum
# --------------------------------------------------------------------------------------

set -ex

# --------------------------------------------------------------------------------------
# include functions
# --------------------------------------------------------------------------------------
source ./functions.sh

# --------------------------------------------------------------------------------------
# include each paramters of conf file.
# --------------------------------------------------------------------------------------
if [[ "$2" = "quantum" ]]; then
    source ./deploy_with_quantum.conf
elif [[ "$2" = "nova-network" ]]; then
    source ./deploy_with_nova-network.conf
fi

# --------------------------------------------------------------------------------------
# initialize
# --------------------------------------------------------------------------------------
function init() {
    apt-get update
    install_package ntp
    cat <<EOF >/etc/ntp.conf
server ntp.ubuntu.com
server 127.127.1.0
fudge 127.127.1.0 stratum 10
EOF

    # setup Ubuntu Cloud Archive repository
    check_codename
    if [[ "$CODENAME" = "quantal" ]]; then
        echo "quantul don't need Ubuntu Cloud Archive repository."
    else
        echo deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/folsom main >> /etc/apt/sources.list.d/folsom.list
        apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 5EDB1B62EC4926EA
        apt-get update
    fi
}

# --------------------------------------------------------------------------------------
# set shell environment
# --------------------------------------------------------------------------------------
function shell_env() {
    # create openstackrc for 'admin' user
    echo 'export SERVICE_TOKEN=admin' >> ~/openstackrc
    echo 'export OS_TENANT_NAME=admin' >> ~/openstackrc
    echo 'export OS_USERNAME=admin' >> ~/openstackrc
    echo 'export OS_PASSWORD=admin' >> ~/openstackrc
    echo "export OS_AUTH_URL=\"http://${KEYSTONE_IP}:5000/v2.0/\"" >> ~/openstackrc
    echo "export SERVICE_ENDPOINT=http://${KEYSTONE_IP}:35357/v2.0" >> ~/openstackrc
    # set ENVs, now use this user 'admin' for installation.
    export SERVICE_TOKEN=admin
    export OS_TENANT_NAME=admin
    export OS_USERNAME=admin
    export OS_PASSWORD=admin
    export OS_AUTH_URL="http://${KEYSTONE_IP}:5000/v2.0/"
    export SERVICE_ENDPOINT="http://${KEYSTONE_IP}:35357/v2.0"

    # create openstackrc for 'demo' user. this user is useful for horizon.
    echo 'export SERVICE_TOKEN=admin' >> ~/openstackrc-demo
    echo 'export OS_TENANT_NAME=service' >> ~/openstackrc-demo
    echo 'export OS_USERNAME=demo' >> ~/openstackrc-demo
    echo 'export OS_PASSWORD=demo' >> ~/openstackrc-demo
    echo "export OS_AUTH_URL=\"http://${KEYSTONE_IP}:5000/v2.0/\"" >> ~/openstackrc-demo
    echo "export SERVICE_ENDPOINT=http://${KEYSTONE_IP}:35357/v2.0" >> ~/openstackrc-demo
}

# --------------------------------------------------------------------------------------
# install mysql
# --------------------------------------------------------------------------------------
function mysql_setup() {
    echo mysql-server-5.5 mysql-server/root_password password ${MYSQL_PASS} | debconf-set-selections
    echo mysql-server-5.5 mysql-server/root_password_again password ${MYSQL_PASS} | debconf-set-selections
    install_package mysql-server python-mysqldb
    sed -i -e 's/127.0.0.1/0.0.0.0/' /etc/mysql/my.cnf
    restart_service mysql
}

# --------------------------------------------------------------------------------------
# install keystone
# --------------------------------------------------------------------------------------
function keystone_setup() {
    install_package keystone python-keystone python-keystoneclient
    
    mysql -uroot -p${MYSQL_PASS} -e 'CREATE DATABASE keystone;'
    mysql -uroot -p${MYSQL_PASS} -e 'CREATE USER keystoneUser;'
    mysql -uroot -p${MYSQL_PASS} -e "GRANT ALL PRIVILEGES ON keystone.* TO 'keystoneUser'@'%';"
    mysql -uroot -p${MYSQL_PASS} -e "SET PASSWORD FOR 'keystoneUser'@'%' = PASSWORD('keystonePass');"
    
    sed -e "s#<HOST>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.keystone/keystone.conf > /etc/keystone/keystone.conf
    restart_service keystone
    keystone-manage db_sync
    
    # Creating Tenants
    keystone tenant-create --name admin
    keystone tenant-create --name service
    
    # Creating Users
    keystone user-create --name admin --pass admin --email admin@example.com
    keystone user-create --name nova --pass nova --email admin@example.com
    keystone user-create --name glance --pass glance --email admin@example.com
    keystone user-create --name cinder --pass cinder --email admin@example.com
    keystone user-create --name demo --pass demo --email demo@example.com
    if [[ "$1" = "quantum" ]]; then
        keystone user-create --name quantum --pass quantum --email admin@example.com
    fi
    
    # Creating Roles
    keystone role-create --name admin
    keystone role-create --name Member
    
    # Adding Roles to Users in Tenants
    USER_LIST_ID_ADMIN=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'admin'" --skip-column-name --silent`
    ROLE_LIST_ID_ADMIN=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from role where name = 'admin'" --skip-column-name --silent`
    TENANT_LIST_ID_ADMIN=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from tenant where name = 'admin'" --skip-column-name --silent`
    
    USER_LIST_ID_NOVA=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'nova'" --skip-column-name --silent`
    TENANT_LIST_ID_SERVICE=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from tenant where name = 'service'" --skip-column-name --silent`
    
    USER_LIST_ID_GLANCE=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'glance'" --skip-column-name --silent`
    USER_LIST_ID_CINDER=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'cinder'" --skip-column-name --silent`
    USER_LIST_ID_DEMO=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'demo'" --skip-column-name --silent`
    
    ROLE_LIST_ID_MEMBER=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from role where name = 'Member'" --skip-column-name --silent`
    if [[ "$1" = "quantum" ]]; then
        USER_LIST_ID_QUANTUM=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from user where name = 'quantum'" --skip-column-name --silent`
    fi
    
    # To add a role of 'admin' to the user 'admin' of the tenant 'admin'.
    keystone user-role-add --user-id $USER_LIST_ID_ADMIN --role-id $ROLE_LIST_ID_ADMIN --tenant-id $TENANT_LIST_ID_ADMIN
    
    # The following commands will add a role of 'admin' to the users 'nova', 'glance' and 'swift' of the tenant 'service'.
    keystone user-role-add --user-id $USER_LIST_ID_NOVA --role-id $ROLE_LIST_ID_ADMIN --tenant-id $TENANT_LIST_ID_SERVICE
    keystone user-role-add --user-id $USER_LIST_ID_GLANCE --role-id $ROLE_LIST_ID_ADMIN --tenant-id $TENANT_LIST_ID_SERVICE
    keystone user-role-add --user-id $USER_LIST_ID_CINDER --role-id $ROLE_LIST_ID_ADMIN --tenant-id $TENANT_LIST_ID_SERVICE
    if [[ "$1" = "quantum" ]]; then
        keystone user-role-add --user-id $USER_LIST_ID_QUANTUM --role-id $ROLE_LIST_ID_ADMIN --tenant-id $TENANT_LIST_ID_SERVICE
    fi
    
    # The 'Member' role is used by Horizon and Swift. So add the 'Member' role accordingly.
    keystone user-role-add --user-id $USER_LIST_ID_ADMIN --role-id $ROLE_LIST_ID_MEMBER --tenant-id $TENANT_LIST_ID_ADMIN
    keystone user-role-add --user-id $USER_LIST_ID_DEMO --role-id $ROLE_LIST_ID_MEMBER --tenant-id $TENANT_LIST_ID_SERVICE
    
    # Creating Services
    keystone service-create --name nova --type compute --description 'OpenStack Compute Service'
    keystone service-create --name glance --type image --description 'OpenStack Image Service'
    keystone service-create --name cinder --type volume --description 'OpenStack Volume Service'
    keystone service-create --name keystone --type identity --description 'OpenStack Identity Service'
    keystone service-create --name ec2 --type ec2 --description 'EC2 Service'
    if [[ "$1" = "quantum" ]]; then
        keystone service-create --name quantum --type network --description 'OpenStack Networking Service'
    fi
    
    keystone service-list
    
    # get service id for each service
    SERVICE_LIST_ID_EC2=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='ec2'" --skip-column-name --silent`
    SERVICE_LIST_ID_IMAGE=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='image'" --skip-column-name --silent`
    SERVICE_LIST_ID_VOLUME=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='volume'" --skip-column-name --silent`
    SERVICE_LIST_ID_IDENTITY=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='identity'" --skip-column-name --silent`
    SERVICE_LIST_ID_COMPUTE=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='compute'" --skip-column-name --silent`
    if [[ "$1" = "quantum" ]]; then
        SERVICE_LIST_ID_NETWORK=`mysql -u root -p${MYSQL_PASS} keystone -e "select id from service where type='network'" --skip-column-name --silent`
    fi
    
    # Creating Endpoints
    keystone endpoint-create --region myregion --service_id $SERVICE_LIST_ID_EC2 --publicurl "http://${NOVA_IP}:8773/services/Cloud" --adminurl "http://${NOVA_IP}:8773/services/Admin" --internalurl "http://${NOVA_IP}:8773/services/Cloud"
    keystone endpoint-create --region myregion --service_id $SERVICE_LIST_ID_IDENTITY --publicurl "http://${KEYSTONE_IP}:5000/v2.0" --adminurl "http://${KEYSTONE_IP}:35357/v2.0" --internalurl "http://${KEYSTONE_IP}:5000/v2.0"
    keystone endpoint-create --region myregion --service_id $SERVICE_LIST_ID_VOLUME --publicurl "http://${NOVA_IP}:8776/v1/\$(tenant_id)s" --adminurl "http://${NOVA_IP}:8776/v1/\$(tenant_id)s" --internalurl "http://${NOVA_IP}:8776/v1/\$(tenant_id)s"
    keystone endpoint-create --region myregion --service_id $SERVICE_LIST_ID_IMAGE --publicurl "http://${GLANCE_IP}:9292/v2" --adminurl "http://${GLANCE_IP}:9292/v2" --internalurl "http://${GLANCE_IP}:9292/v2"
    keystone endpoint-create --region myregion --service_id $SERVICE_LIST_ID_COMPUTE --publicurl "http://${NOVA_IP}:8774/v2/\$(tenant_id)s" --adminurl "http://${NOVA_IP}:8774/v2/\$(tenant_id)s" --internalurl "http://${NOVA_IP}:8774/v2/\$(tenant_id)s"
    if [[ "$1" = "quantum" ]]; then
        keystone endpoint-create --region myregion --service-id $SERVICE_LIST_ID_NETWORK --publicurl "http://${QUANTUM_IP}:9696/" --adminurl "http://${QUANTUM_IP}:9696/" --internalurl "http://${QUANTUM_IP}:9696/"
    fi
}

# --------------------------------------------------------------------------------------
# install glance
# --------------------------------------------------------------------------------------
function glance_setup() {
    # install packages
    install_package glance glance-api glance-common glance-registry python-glance python-mysqldb python-keystone python-keystoneclient mysql-client python-glanceclient
    
    # create database for keystone service
    mysql -uroot -p${MYSQL_PASS} -e "CREATE DATABASE glance;"
    mysql -uroot -p${MYSQL_PASS} -e "GRANT ALL ON glance.* TO 'glanceUser'@'%' IDENTIFIED BY 'glancePass';"
    
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.glance/glance-api.conf > /etc/glance/glance-api.conf
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.glance/glance-registry.conf > /etc/glance/glance-registry.conf
    
    # restart process and syncing database
    restart_service glance-registry
    restart_service glance-api
    glance-manage db_sync

    # install cirros 0.3.0 x86_64 os image
    if [[ -f ./os.img ]]; then
        mv ./os.img ./os.img.bk
    fi
    wget ${OS_IMAGE_URL} -O ./os.img
    glance add name="${OS_IMAGE_NAME}" is_public=true container_format=ovf disk_format=qcow2 < ./os.img
}

# --------------------------------------------------------------------------------------
# install openvswitch
# --------------------------------------------------------------------------------------
function openvswitch_setup() {
    check_codename
    if [[ "$CODENAME" = "precise" ]]; then
        install_package openvswitch-switch openvswitch-datapath-dkms
    else
        install_package openvswitch-switch
    fi
    # create bridge interfaces
    ovs-vsctl add-br br-int
    ovs-vsctl add-br br-eth1
    ovs-vsctl add-port br-eth1 ${DATA_NIC}
    ovs-vsctl add-br br-ex
    ovs-vsctl add-port br-ex ${PUBLIC_NIC}
}

# --------------------------------------------------------------------------------------
# install quantum
# --------------------------------------------------------------------------------------
function allinone_quantum_setup() {
    # install packages
    install_package quantum-server python-cliff python-pyparsing quantum-plugin-openvswitch quantum-plugin-openvswitch-agent quantum-dhcp-agent quantum-l3-agent
    # create database for quantum
    mysql -u root -p${MYSQL_PASS} -e "CREATE DATABASE quantum;"
    mysql -u root -p${MYSQL_PASS} -e "GRANT ALL ON quantum.* TO 'quantumUser'@'%' IDENTIFIED BY 'quantumPass';"
    
    # set configuration files for quantum
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.quantum/api-paste.ini > /etc/quantum/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<CONTROLLER_NODE_PUB_IP>#${CONTROLLER_NODE_PUB_IP}#" $BASE_DIR/conf/etc.quantum/l3_agent.ini > /etc/quantum/l3_agent.ini
    sed -e "s#<RABBIT_IP>#${RABBIT_IP}#" $BASE_DIR/conf/etc.quantum/quantum.conf > /etc/quantum/quantum.conf
    if [[ "$NETWORK_TYPE" = "gre" ]]; then
        sed -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.gre > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    elif [[ "$NETWORK_TYPE" = "vlan" ]]; then
        sed -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.vlan > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    else
        echo "<network_type> must be 'gre' or 'vlan'."
        exit 1
    fi
    
    # restart processes
    restart_service quantum-server
    restart_service quantum-plugin-openvswitch-agent
    restart_service quantum-dhcp-agent
    restart_service quantum-l3-agent
}

# --------------------------------------------------------------------------------------
# install quantum for controller node
# --------------------------------------------------------------------------------------
function controller_quantum_setup() {
    # install packages
    install_package quantum-server quantum-plugin-openvswitch
    # create database for quantum
    mysql -u root -p${MYSQL_PASS} -e "CREATE DATABASE quantum;"
    mysql -u root -p${MYSQL_PASS} -e "GRANT ALL ON quantum.* TO 'quantumUser'@'%' IDENTIFIED BY 'quantumPass';"
    
    # set configuration files for quantum
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.quantum/api-paste.ini > /etc/quantum/api-paste.ini
    if [[ "$NETWORK_TYPE" = "gre" ]]; then
        sed -e "s#<QUANTUM_IP>#${CONTROLLER_NODE_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.gre > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    elif [[ "$NETWORK_TYPE" = "vlan" ]]; then
        sed -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.vlan > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    else
        echo "<network_type> must be 'gre' or 'vlan'."
        exit 1
    fi
    
    # restart process
    restart_service quantum-server
}

# --------------------------------------------------------------------------------------
# install quantum for network node
# --------------------------------------------------------------------------------------
function network_quantum_setup() {
    # install packages
    install_package mysql-client
    install_package quantum-plugin-openvswitch-agent quantum-dhcp-agent quantum-l3-agent vlan bridge-utils
    
    # set configuration files for quantum
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.quantum/api-paste.ini > /etc/quantum/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<CONTROLLER_NODE_PUB_IP>#${CONTROLLER_NODE_PUB_IP}#" $BASE_DIR/conf/etc.quantum/l3_agent.ini > /etc/quantum/l3_agent.ini
    sed -e "s#<RABBIT_IP>#${RABBIT_IP}#" $BASE_DIR/conf/etc.quantum/quantum.conf > /etc/quantum/quantum.conf

    if [[ "$NETWORK_TYPE" = "gre" ]]; then
        sed -e "s#<QUANTUM_IP>#${NETWORK_NODE_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.gre > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    elif [[ "$NETWORK_TYPE" = "vlan" ]]; then
        sed -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.vlan > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    else
        echo "<network_type> must be 'gre' or 'vlan'."
        exit 1
    fi
    
    # restart processes
    restart_service quantum-plugin-openvswitch-agent
    restart_service quantum-dhcp-agent
    restart_service quantum-l3-agent
}

# --------------------------------------------------------------------------------------
# create network via quantum
# --------------------------------------------------------------------------------------
function create_network() {
    if [[ "$NETWORK_TYPE" = "gre" ]]; then
        # create internal network
        TENANT_ID=$(keystone tenant-list | grep " service " | get_field 1)
        INT_NET_ID=$(quantum net-create --tenant-id ${TENANT_ID} int_net | grep ' id ' | get_field 2)
        INT_SUBNET_ID=$(quantum subnet-create --tenant-id ${TENANT_ID} --ip_version 4 --gateway ${INT_NET_GATEWAY} ${INT_NET_ID} ${INT_NET_RANGE} | grep ' id ' | get_field 2)
        quantum subnet-update ${INT_SUBNET_ID} list=true --dns_nameservers 8.8.8.8 8.8.4.4
        INT_ROUTER_ID=$(quantum router-create --tenant-id ${TENANT_ID} router-admin | grep ' id ' | get_field 2)
        quantum router-interface-add ${INT_ROUTER_ID} ${INT_SUBNET_ID}
        # create external network
        EXT_NET_ID=$(quantum net-create ext_net -- --router:external=True | grep ' id ' | get_field 2)
        quantum subnet-create --gateway=${EXT_NET_GATEWAY} --allocation-pool start=${EXT_NET_START},end=${EXT_NET_END} ${EXT_NET_ID} ${EXT_NET_RANGE} -- --enable_dhcp=False
        quantum router-gateway-set ${INT_ROUTER_ID} ${EXT_NET_ID}
    elif [[ "$NETWORK_TYPE" = "vlan" ]]; then
        # create internal network
        TENANT_ID=$(keystone tenant-list | grep " service " | get_field 1)
        INT_NET_ID=$(quantum net-create --tenant-id ${TENANT_ID} int_net --provider:network_type vlan --provider:physical_network physnet1 --provider:segmentation_id 1024| grep ' id ' | get_field 2)
        INT_SUBNET_ID=$(quantum subnet-create --tenant-id ${TENANT_ID} --ip_version 4 --gateway ${INT_NET_GATEWAY} ${INT_NET_ID} ${INT_NET_RANGE} | grep ' id ' | get_field 2)
        quantum subnet-update ${INT_SUBNET_ID} list=true --dns_nameservers 8.8.8.8 8.8.4.4
        INT_ROUTER_ID=$(quantum router-create --tenant-id ${TENANT_ID} router-admin | grep ' id ' | get_field 2)
        quantum router-interface-add ${INT_ROUTER_ID} ${INT_SUBNET_ID}
        # create external network
        EXT_NET_ID=$(quantum net-create ext_net -- --router:external=True | grep ' id ' | get_field 2)
        quantum subnet-create --gateway=${EXT_NET_GATEWAY} --allocation-pool start=${EXT_NET_START},end=${EXT_NET_END} ${EXT_NET_ID} ${EXT_NET_RANGE} -- --enable_dhcp=False
        quantum router-gateway-set ${INT_ROUTER_ID} ${EXT_NET_ID}
    else
        echo "network type : gre, vlan"
        echo "no such parameter of network type"
        exit 1
    fi
}

# --------------------------------------------------------------------------------------
# create network via nova-network
# --------------------------------------------------------------------------------------
function create_network_nova-network() {
    check_para ${FIXED_RANGE}
    check_para ${FLOATING_RANGE}
    nova-manage network create private --fixed_range_v4=${FIXED_RANGE} --num_networks=1 --bridge=br100 --bridge_interface=eth0 --network_size=${NETWORK_SIZE} --dns1=8.8.8.8 --dns2=8.8.4.4 --multi_host=T
    nova-manage floating create --ip_range=${FLOATING_RANGE}
}

# --------------------------------------------------------------------------------------
# install nova for controller node with nova-network
# --------------------------------------------------------------------------------------
function controller_nova_setup_nova-network() {
    # install dependency packages
    install_package kvm libvirt-bin pm-utils
    # erase dusts
    virsh net-destroy default
    virsh net-undefine default
    restart_service libvirt-bin
    
    # install nova packages
    install_package nova-api nova-cert nova-common novnc nova-compute-kvm nova-consoleauth nova-scheduler nova-novncproxy rabbitmq-server vlan bridge-utils nova-network nova-console websockify novnc
    # create database for nova
    mysql -u root -p${MYSQL_PASS} -e "CREATE DATABASE nova;"
    mysql -u root -p${MYSQL_PASS} -e "GRANT ALL ON nova.* TO 'novaUser'@'%' IDENTIFIED BY 'novaPass';"
    
    # deploy configuration for nova
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<NOVA_IP>#${NOVA_IP}#" -e "s#<GLANCE_IP>#${GLANCE_IP}#" -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" -e "s#<COMPUTE_NODE_IP>#127.0.0.1#" -e "s#<FIXED_RANGE>#${FIXED_RANGE}#" -e "s#<FIXED_START_ADDR>#${FIXED_START_ADDR}#" -e "s#<NETWORK_SIZE>#${NETWORK_SIZE}#" $BASE_DIR/conf/etc.nova/nova.conf.nova-network > /etc/nova/nova.conf
    
    chown -R nova. /etc/nova
    chmod 644 /etc/nova/nova.conf
    nova-manage db sync

    # restart all services of nova
    cd /etc/init.d/; for i in $( ls nova-* ); do sudo service $i restart; done
    nova-manage service list
}

# --------------------------------------------------------------------------------------
# install nova for compute node with nova-network
# --------------------------------------------------------------------------------------
function compute_nova_setup_nova-network() {
    # install packages
    install_package nova-compute nova-network nova-api-metadata
    # erase dusts
    virsh net-destroy default
    virsh net-undefine default
    restart_service libvirt-bin

    # deploy configuration for nova
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<NOVA_IP>#${NOVA_IP}#" -e "s#<GLANCE_IP>#${GLANCE_IP}#" -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" -e "s#<COMPUTE_NODE_IP>#${COMPUTE_NODE_IP}#" -e "s#<FIXED_RANGE>#${FIXED_RANGE}#" -e "s#<FIXED_START_ADDR>#${FIXED_START_ADDR}#" -e "s#<NETWORK_SIZE>#${NETWORK_SIZE}#" $BASE_DIR/conf/etc.nova/nova.conf.nova-network > /etc/nova/nova.conf
    
    chown -R nova. /etc/nova
    chmod 644 /etc/nova/nova.conf
    #nova-manage db sync

    # restart all services of nova
    cd /etc/init.d/; for i in $( ls nova-* ); do sudo service $i restart; done
    nova-manage service list
}

# --------------------------------------------------------------------------------------
# install nova for all in one with quantum
# --------------------------------------------------------------------------------------
function allinone_nova_setup() {
    install_package kvm libvirt-bin pm-utils
    virsh net-destroy default
    virsh net-undefine default
    restart_service libvirt-bin
    
    install_package nova-api nova-cert nova-common novnc nova-compute-kvm nova-consoleauth nova-scheduler nova-novncproxy rabbitmq-server vlan bridge-utils
    mysql -u root -p${MYSQL_PASS} -e "CREATE DATABASE nova;"
    mysql -u root -p${MYSQL_PASS} -e "GRANT ALL ON nova.* TO 'novaUser'@'%' IDENTIFIED BY 'novaPass';"
    
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<NOVA_IP>#${NOVA_IP}#" -e "s#<GLANCE_IP>#${GLANCE_IP}#" -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" -e "s#<COMPUTE_NODE_IP>#127.0.0.1#" $BASE_DIR/conf/etc.nova/nova.conf > /etc/nova/nova.conf
    
    chown -R nova. /etc/nova
    chmod 644 /etc/nova/nova.conf
    nova-manage db sync
    cd /etc/init.d/; for i in $( ls nova-* ); do sudo service $i restart; done
    nova-manage service list
}

# --------------------------------------------------------------------------------------
# install nova for controller node with quantum
# --------------------------------------------------------------------------------------
function controller_nova_setup() {
    # install packages
    install_package nova-api nova-cert novnc nova-consoleauth nova-scheduler nova-novncproxy rabbitmq-server vlan bridge-utils
    mysql -u root -p${MYSQL_PASS} -e "CREATE DATABASE nova;"
    mysql -u root -p${MYSQL_PASS} -e "GRANT ALL ON nova.* TO 'novaUser'@'%' IDENTIFIED BY 'novaPass';"
    
    # set configuration files for nova
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<NOVA_IP>#${NOVA_IP}#" -e "s#<GLANCE_IP>#${GLANCE_IP}#" -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" -e "s#<COMPUTE_NODE_IP>#127.0.0.1#" $BASE_DIR/conf/etc.nova/nova.conf > /etc/nova/nova.conf
    
    chown -R nova. /etc/nova
    chmod 644 /etc/nova/nova.conf
    nova-manage db sync
    # restart processes
    cd /etc/init.d/; for i in $( ls nova-* ); do sudo service $i restart; done
    nova-manage service list
}

# --------------------------------------------------------------------------------------
# install additional nova for compute node with quantum
# --------------------------------------------------------------------------------------
function compute_nova_setup() {
    # install dependency packages
    install_package vlan bridge-utils kvm libvirt-bin pm-utils
    virsh net-destroy default
    virsh net-undefine default

    # install openvswitch and add bridge interfaces
    install_package openvswitch-switch
    ovs-vsctl add-br br-int
    ovs-vsctl add-br br-eth1
    ovs-vsctl add-port br-eth1 ${DATA_NIC_COMPUTE}

    # quantum setup
    install_package quantum-plugin-openvswitch-agent
    if [[ "$NETWORK_TYPE" = "gre" ]]; then
        sed -e "s#<QUANTUM_IP>#${COMPUTE_NODE_IP}#" -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.gre > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    elif [[ "$NETWORK_TYPE" = "vlan" ]]; then
        sed -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.quantum.plugins.openvswitch/ovs_quantum_plugin.ini.vlan > /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini
    else
        echo "<network_type> must be 'gre' or 'vlan'."
        exit 1
    fi
    sed -e "s#<RABBIT_IP>#${CONTROLLER_NODE_IP}#" $BASE_DIR/conf/etc.quantum/quantum.conf > /etc/quantum/quantum.conf
    service quantum-plugin-openvswitch-agent restart

    # nova setup
    install_package nova-api-metadata nova-compute-kvm
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" -e "s#<NOVA_IP>#${NOVA_IP}#" -e "s#<GLANCE_IP>#${GLANCE_IP}#" -e "s#<QUANTUM_IP>#${QUANTUM_IP}#" -e "s#<DB_IP>#${DB_IP}#" -e "s#<COMPUTE_NODE_IP>#${COMPUTE_NODE_IP}#" $BASE_DIR/conf/etc.nova/nova.conf > /etc/nova/nova.conf
    cp $BASE_DIR/conf/etc.nova/nova-compute.conf /etc/nova/nova-compute.conf
    
    chown -R nova. /etc/nova
    chmod 644 /etc/nova/nova.conf
    nova-manage db sync

    # restart processes
    cd /etc/init.d/; for i in $( ls nova-* ); do sudo service $i restart; done
    nova-manage service list
}

# --------------------------------------------------------------------------------------
# install cinder
# --------------------------------------------------------------------------------------
function cinder_setup() {
    # install packages
    install_package cinder-api cinder-scheduler cinder-volume iscsitarget open-iscsi iscsitarget-dkms
    # create databases
    mysql -uroot -p${MYSQL_PASS} -e "CREATE DATABASE cinder;"
    mysql -uroot -p${MYSQL_PASS} -e "GRANT ALL ON cinder.* TO 'cinderUser'@'%' IDENTIFIED BY 'cinderPass';"
    
    # set configuration files for cinder
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.nova/api-paste.ini > /etc/nova/api-paste.ini
    sed -e "s#<KEYSTONE_IP>#${KEYSTONE_IP}#" $BASE_DIR/conf/etc.cinder/api-paste.ini > /etc/cinder/api-paste.ini
    sed -e "s#<DB_IP>#${DB_IP}#" $BASE_DIR/conf/etc.cinder/cinder.conf > /etc/cinder/cinder.conf
    
    cinder-manage db sync

    # create pyshical volume and volume group
    pvcreate ${CINDER_VOLUME}
    vgcreate cinder-volumes ${CINDER_VOLUME}

    # restart processes
    restart_service cinder-volume
    restart_service cinder-api
}

# --------------------------------------------------------------------------------------
# install horizon
# --------------------------------------------------------------------------------------
function horizon_setup() {
    install_package openstack-dashboard memcached
    cp $BASE_DIR/conf/etc.openstack-dashboard/local_settings.py /etc/openstack-dashboard/local_settings.py
    restart_service apache2
}

# --------------------------------------------------------------------------------------
#  make seciruty group rule named 'default' to allow SSH and ICMP traffic
# --------------------------------------------------------------------------------------
function scgroup_allow() {
    nova --no-cache secgroup-add-rule default tcp 22 22 0.0.0.0/0
    nova --no-cache secgroup-add-rule default icmp -1 -1 0.0.0.0/0
}

# --------------------------------------------------------------------------------------
# Main Function
# --------------------------------------------------------------------------------------
if [[ "$2" = "nova-network" ]]; then
    case "$1" in
        allinone)
            NOVA_IP=${HOST_IP};     check_para ${NOVA_IP}
            CINDER_IP=${HOST_IP};   check_para ${CINDER_IP}
            DB_IP=${HOST_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${HOST_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${HOST_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${HOST_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${HOST_IP};   check_para ${RABBIT_IP}
            check_env 
            shell_env
            init
            mysql_setup
            keystone_setup nova-network
            glance_setup
            controller_nova_setup_nova-network
            cinder_setup
            horizon_setup
            scgroup_allow
            ;;
        controller)
            NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
            CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
            DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${CONTROLLER_NODE_IP};   check_para ${RABBIT_IP}
            check_env 
            shell_env
            init
            mysql_setup
            keystone_setup nova-network
            glance_setup
            controller_nova_setup_nova-network
            cinder_setup
            horizon_setup
            scgroup_allow
            ;;
        compute)
            NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
            CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
            DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${CONTROLLER_NODE_IP};   check_para ${RABBIT_IP}
            check_env 
            shell_env
            init
            compute_nova_setup_nova-network
            ;;
        create_network)
            if [[ "${HOST_IP}" ]]; then
                NOVA_IP=${HOST_IP};            check_para ${NOVA_IP}
                CINDER_IP=${HOST_IP};          check_para ${CINDER_IP}
                DB_IP=${HOST_IP};              check_para ${DB_IP}
                KEYSTONE_IP=${HOST_IP};        check_para ${KEYSTONE_IP}
                GLANCE_IP=${HOST_IP};          check_para ${GLANCE_IP}
                QUANTUM_IP=${HOST_IP};         check_para ${QUANTUM_IP}
            elif [[ "${CONTROLLER_NODE_IP}" ]]; then
                NOVA_IP=${CONTROLLER_NODE_IP};            check_para ${NOVA_IP}
                CINDER_IP=${CONTROLLER_NODE_IP};          check_para ${CINDER_IP}
                DB_IP=${CONTROLLER_NODE_IP};              check_para ${DB_IP}
                KEYSTONE_IP=${CONTROLLER_NODE_IP};        check_para ${KEYSTONE_IP}
                GLANCE_IP=${CONTROLLER_NODE_IP};          check_para ${GLANCE_IP}
                QUANTUM_IP=${CONTROLLER_NODE_IP};         check_para ${QUANTUM_IP}
            else
                print_syntax
            fi
 
            check_env
            shell_env
            create_network_nova-network
            ;;
        *)
            print_syntax
            ;;
    esac
elif [[ "$2" = "quantum" ]]; then
    case "$1" in
        allinone)
            NOVA_IP=${HOST_IP};     check_para ${NOVA_IP}
            CINDER_IP=${HOST_IP};   check_para ${CINDER_IP}
            DB_IP=${HOST_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${HOST_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${HOST_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${HOST_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${HOST_IP};   check_para ${RABBIT_IP}
            CONTROLLER_NODE_PUB_IP=${HOST_PUB_IP}; check_para ${CONTROLLER_NODE_PUB_IP}
            check_env 
            shell_env
            init
            mysql_setup
            keystone_setup quantum
            glance_setup
            openvswitch_setup
            allinone_quantum_setup
            allinone_nova_setup
            cinder_setup
            horizon_setup
            scgroup_allow
            ;;
        controller)
            NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
            CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
            DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${CONTROLLER_NODE_IP};   check_para ${RABBIT_IP}
            check_env 
            shell_env
            init
            mysql_setup
            keystone_setup quantum
            glance_setup
            controller_quantum_setup
            controller_nova_setup
            cinder_setup
            horizon_setup
            scgroup_allow
            ;;
        network)
            NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
            CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
            DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${CONTROLLER_NODE_IP};   check_para ${RABBIT_IP}
            check_env 
            shell_env
            init
            openvswitch_setup
            network_quantum_setup
            ;;
        compute)
            NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
            CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
            DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
            KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
            GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
            QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            RABBIT_IP=${CONTROLLER_NODE_IP};   check_para ${RABBIT_IP}
            check_env
            shell_env
            init
            compute_nova_setup
            ;;
        create_network)
            if [[ "${HOST_IP}" ]]; then
                NOVA_IP=${HOST_IP};                check_para ${NOVA_IP}
                CINDER_IP=${HOST_IP};              check_para ${CINDER_IP}
                DB_IP=${HOST_IP};                  check_para ${DB_IP}
                KEYSTONE_IP=${HOST_IP};            check_para ${KEYSTONE_IP}
                GLANCE_IP=${HOST_IP};              check_para ${GLANCE_IP}
                QUANTUM_IP=${HOST_IP};             check_para ${QUANTUM_IP}
            elif [[ "${CONTROLLER_NODE_IP}" ]]; then
                NOVA_IP=${CONTROLLER_NODE_IP};     check_para ${NOVA_IP}
                CINDER_IP=${CONTROLLER_NODE_IP};   check_para ${CINDER_IP}
                DB_IP=${CONTROLLER_NODE_IP};       check_para ${DB_IP}
                KEYSTONE_IP=${CONTROLLER_NODE_IP}; check_para ${KEYSTONE_IP}
                GLANCE_IP=${CONTROLLER_NODE_IP};   check_para ${GLANCE_IP}
                QUANTUM_IP=${CONTROLLER_NODE_IP};  check_para ${QUANTUM_IP}
            else
                print_syntax
            fi

            check_env
            shell_env
            create_network
            ;;
        *)
            print_syntax
            ;;
    esac
else
    print_syntax
fi

exit 0
