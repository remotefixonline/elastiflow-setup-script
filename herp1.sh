#!/bin/bash
#This script is used to install elastiflow on top of cowstack and  GeoLite2
#Elasticsearch requires Java 8 or later. Use whatever you want its going to crash.  i'm text not a cop.  remember after you find and fix whatever crashed do a systemctl daemon-reload 


MYDOMAIN="remotefixonline"


#Verify running as root:
check_user() {
    USER_ID=$(/usr/bin/id -u)
    return $USER_ID
}

if [ "$USER_ID" > 0 ]; then
    echo "You must be a root user" 2>&1
    exit 1
fi

#Update system packages
update_system_packages() {
    echo -n "Updating Packages \n"
    echo "-----------------------------------------"
    apt-get -y update
}

#Check Apache2 Packages
check_apache2() {
    echo -n "Checking if Apache2 is installed \n"
    echo    "--------------------------------"
    APACHE2=$(dpkg-query -W -f='${Status}' apache 2>/dev/null | grep -c "ok installed")
    if [ $APACHE2 -eq 0 ] ; then
        echo "Apache2 not installed - Installing Apache2 now - Please wait \n"
        apt-get install -y apache2 apache2-doc apache2-utils
    else
        echo "Apache2 is installed "
    fi
}

#check if java installed
check_java() {
    clear
    echo -n "checking if java is installed \n"
    echo    "--------------------------------"
    JAVA=$(which java | wc -l)
    JAVA_REQ=$(java -version 2> /tmp/version && awk '/version/ { gsub(/"/, "", $NF); print ( $NF < 1.8 ) ? "YES" : "NO" }' /tmp/version)
    if [ $JAVA -eq 0 ] ; then
        #install java
        echo "Installing Java 8 - Please wait "
        echo "--------------------------------"
        apt-get install -y python-software-properties wget curl software-properties-common apt-transport-https
        echo deb http://http.debian.net/debian jessie-backports main >> /etc/apt/sources.list
        apt-get update && apt-get install -t jessie-backports openjdk-8-jdk
        #update-alternatives --config java
        #Elasticsearch requires Java 8 or later
        elif [ "$JAVA_REQ" = 'YES' ]; then
        apt-get update && apt-get install -y openjdk-8-jdk
    fi
}

#Install and Configure Elasticsearch
install_elasticsearch() {
    clear
    echo -n "Installing elasticsearch \n"
    echo    "---------------------------"
    #import PGP key
    wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add -
    #update apt sources list
    echo "deb https://artifacts.elastic.co/packages/oss-7.x/apt stable main" | tee -a /etc/apt/sources.list.d/oss-elastic-7.x.list
    apt-get update && apt-get install -y elasticsearch-oss
    #Elasticsearch is not started automatically after installation
    echo -n "Updating start daemon \n"
    echo    "---------------------------"
    CMD=$(command -v systemctl)
    if [ $CMD > /dev/null ] ; then
        systemctl daemon-reload
        systemctl enable elasticsearch.service
    else
        update-rc.d elasticsearch defaults 95 10
    fi
}

configure_elasticsearch() {
    clear
    echo -n "Configuring elasticsearch \n"
    echo    "---------------------------"
    cd /etc/elasticsearch/ || exit
    #bootstrap.memory_lock: true
    sed -i '/bootstrap.memory_lock:/s/^#//g' elasticsearch.yml
    #network.host: localhost
    sed -i '/network.host/anetwork.host: localhost'  elasticsearch.yml
    #http.port: 9200
    sed -i '/http.port:/s/^#//g' elasticsearch.yml
    #LimitMEMLOCK=infinity
    sed -i '/LimitMEMLOCK=/s/^#//g' /usr/lib/systemd/system/elasticsearch.service
    #MAX_LOCKED_MEMORY=unlimited
    sed -i '/MAX_LOCKED_MEMORY=/s/^#//g' /etc/default/elasticsearch
    #start service
    systemctl daemon-reload
    echo -n "Starting Service elasticsearch \n"
    echo    "------------------------------"
    service elasticsearch start  
    sleep 60
    #check if service is running
    SVC='elasticsearch'
    if ps ax | grep -v grep | grep $SVC > /dev/null ; then
        echo "Elasticsearch service is running"
    else
        echo "Elasticsearch Server is stopped - please check your installation"
        exit 1
    fi
}


#Install and Configure Kibana with Apache2
install_kibana() {
    clear
    echo -n "Installing kibana \n"
    echo    "---------------------------"
    #get eth IP
    IP=$(ip addr show |grep "inet " |grep -v 127.0.0. |head -1|cut -d" " -f6|cut -d/ -f1)
    #install package
    apt-get install -y kibana-oss
    cd /etc/kibana || exit
    #server.port: 5601
    sed -i "/server.port:/s/^#//g" /etc/kibana/kibana.yml
    #The default is 'localhost', which usually means remote machines will not be able to connect.
    #server.host: "localhost"
    sed -i "/server.host/aserver.host: ${IP}"  /etc/kibana/kibana.yml
    #Elastic url
    sed -i '/elasticsearch.url:/s/^#//g' /etc/kibana/kibana.yml
    #start kibana
    echo -n "Updating start daemon Kibana \n"
    echo    "---------------------------"
    CMD=$(command -v systemctl)
    if [ $CMD > /dev/null ] ; then
        systemctl daemon-reload
        systemctl enable kibana.service
        systemctl start kibana.service
    else
        update-rc.d kibana defaults 95 10
        service kibana start
    fi
    #enable Kibana mod proxy
    a2enmod proxy
    a2enmod proxy_http
    a2enmod rewrite && /etc/init.d/apache2 restart
        
}


#Create apache config file for kibana
#please edit ServerName and ServerAdmin
configure_kibana() {
    clear
    echo -n "Configuring Kibana \n"
    echo    "---------------------------"
    cd /etc/apache2/sites-available || exit
    #create file
    touch  kibana.conf
    #insert config
    APACHE_LOG_DIR='/var/log/apache2'
cat <<- EOF > kibana.conf
  <VirtualHost *:80>
  ServerName kibana.$MYDOMAIN
  ServerAdmin admin@$MYDOMAIN
    # Reverse Proxy
    ProxyRequests Off
    ProxyPass / http://127.0.0.1:5601
    ProxyPassReverse / http://127.0.0.1:5601
    RewriteEngine on
    RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} !-f
    RewriteRule .* http://127.0.0.1:5601%{REQUEST_URI} [P,QSA]
    ErrorLog ${APACHE_LOG_DIR}/kibana_error.log
    LogLevel warn
    CustomLog ${APACHE_LOG_DIR}/kibana_access.log combined
    </VirtualHost>
EOF
    
    #enable apache config file
    a2ensite kibana.conf
    service apache2 reload

    #check if KIBANA port is active
    KBSVC='kibana'
    if ps ax | grep -v grep | grep $KBSVC > /dev/null ; then
        echo "Kibana service is running \n"
    else
        echo "Kibana Server is stopped - please check your installation"
        exit 1  
    fi
     service apache2 reload
}

#Install and Configure Logstash
install_logstash() {
    #install pacjage
    apt-get install -y logstash-oss
    #create config file
    touch /etc/logstash/conf.d/logstash.conf
    cd /etc/logstash/conf.d/ || exit
    #start logstash
    systemctl daemon-reload
    systemctl start logstash.service
    systemctl enable logstash.service
    #install geolocation data for maps
    cd /etc/logstash || exit
    curl -O "http://geolite.maxmind.com/download/geoip/database/GeoLite2-City.mmdb.gz"
    gunzip GeoLite2-City.mmdb.gz
}

test_elasticsearch_port(){
clear
    echo -n "Testing if Elasticsearch is Ruuning on port 9200 \n"
    echo    "---------------------------------------------------"   
PORT=9200
URL="http://localhost:$PORT"
# Check that Elasticsearch is running
curl -s $URL 2>&1 > /dev/null
if [ $? != 0 ]; then
    echo "Unable to contact Elasticsearch on port $PORT."
    echo "Please ensure Elasticsearch is running and can be reached at $URL"
    exit -1
    else
    echo -n "Service is Running \n"
    
fi
}

