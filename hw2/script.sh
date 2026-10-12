#!/bin/bash
set -e

HADOOP_DIR="hadoop-3.4.0"
HADOOP_HOME="/home/team/${HADOOP_DIR}"
CONF_DIR="${HADOOP_HOME}/etc/hadoop"
SSH_KEY="$HOME/.ssh/team_internal"

NN_NODE="team-10-nn"
WORKERS=("team-10-nn" "team-10-00" "team-10-01")
ALL_NODES=("team-10-nn" "team-10-00" "team-10-01" "team-10-en")

NM_MEMORY_MB=2048
NM_VCORES=2

UI_USER="${UI_USER:-admin}"
UI_PASSWORD="${UI_PASSWORD:-}"

# порт на edge,узел, ip, внутренний порт, название
UIS=(
    "9870  team-10-nn 10.10.0.11 9870  NameNode"
    "9868  team-10-nn 10.10.0.11 9868  Secondary NameNode"
    "9864  team-10-nn 10.10.0.11 9864  DataNode (team-10-nn)"
    "9865  team-10-00 10.10.0.12 9864  DataNode (team-10-00)"
    "9866  team-10-01 10.10.0.13 9864  DataNode (team-10-01)"
    "8088  team-10-nn 10.10.0.11 8088  YARN ResourceManager"
    "8042  team-10-nn 10.10.0.11 8042  YARN NodeManager (team-10-nn)"
    "8043  team-10-00 10.10.0.12 8042  YARN NodeManager (team-10-00)"
    "8044  team-10-01 10.10.0.13 8042  YARN NodeManager (team-10-01)"
    "19888 team-10-nn 10.10.0.11 19888 MapReduce JobHistory Server"
)

rsh() {
    local node="$1"; shift
    ssh -i "$SSH_KEY" team@"$node" "source ~/.profile && $*"
}

echo "проверяем hdfs"
if ! rsh "$NN_NODE" "jps | grep -qw NameNode"; then
    rsh "$NN_NODE" "start-dfs.sh"
fi
rsh "$NN_NODE" "hdfs dfsadmin -safemode wait"

echo "YARN и MapReduce"
TMP=$(mktemp -d)

cat << EOF > "$TMP/yarn-site.xml"
<configuration>
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>${NN_NODE}</value>
    </property>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.nodemanager.env-whitelist</name>
        <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_HOME,HADOOP_MAPRED_HOME,PATH,LANG,TZ</value>
    </property>
    <property>
        <name>yarn.nodemanager.resource.memory-mb</name>
        <value>${NM_MEMORY_MB}</value>
    </property>
    <property>
        <name>yarn.nodemanager.resource.cpu-vcores</name>
        <value>${NM_VCORES}</value>
    </property>
    <property>
        <name>yarn.scheduler.minimum-allocation-mb</name>
        <value>256</value>
    </property>
    <property>
        <name>yarn.scheduler.maximum-allocation-mb</name>
        <value>${NM_MEMORY_MB}</value>
    </property>
    <property>
        <name>yarn.nodemanager.vmem-check-enabled</name>
        <value>false</value>
    </property>
    <property>
        <name>yarn.log-aggregation-enable</name>
        <value>true</value>
    </property>
    <property>
        <name>yarn.log.server.url</name>
        <value>http://${NN_NODE}:19888/jobhistory/logs</value>
    </property>
</configuration>
EOF

cat << EOF > "$TMP/mapred-site.xml"
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
    <property>
        <name>yarn.app.mapreduce.am.env</name>
        <value>HADOOP_MAPRED_HOME=${HADOOP_HOME}</value>
    </property>
    <property>
        <name>mapreduce.map.env</name>
        <value>HADOOP_MAPRED_HOME=${HADOOP_HOME}</value>
    </property>
    <property>
        <name>mapreduce.reduce.env</name>
        <value>HADOOP_MAPRED_HOME=${HADOOP_HOME}</value>
    </property>
    <property>
        <name>yarn.app.mapreduce.am.resource.mb</name>
        <value>512</value>
    </property>
    <property>
        <name>mapreduce.map.memory.mb</name>
        <value>512</value>
    </property>
    <property>
        <name>mapreduce.reduce.memory.mb</name>
        <value>512</value>
    </property>
    <property>
        <name>mapreduce.map.java.opts</name>
        <value>-Xmx384m</value>
    </property>
    <property>
        <name>mapreduce.reduce.java.opts</name>
        <value>-Xmx384m</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.address</name>
        <value>${NN_NODE}:10020</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.webapp.address</name>
        <value>${NN_NODE}:19888</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.intermediate-done-dir</name>
        <value>/mr-history/tmp</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.done-dir</name>
        <value>/mr-history/done</value>
    </property>
</configuration>
EOF

for node in "${ALL_NODES[@]}"; do
    scp -i "$SSH_KEY" "$TMP/yarn-site.xml" "$TMP/mapred-site.xml" \
        team@"$node":"${CONF_DIR}/"
    ssh -i "$SSH_KEY" team@"$node" "
        grep -q '^export YARN_RESOURCEMANAGER_USER' ${CONF_DIR}/hadoop-env.sh || \
        printf '%s\n' 'export YARN_RESOURCEMANAGER_USER=team' 'export YARN_NODEMANAGER_USER=team' >> ${CONF_DIR}/hadoop-env.sh"
done
rm -rf "$TMP"

echo "готовим каталоги"
rsh "$NN_NODE" "hdfs dfs -mkdir -p /tmp /user/team /mr-history/tmp /mr-history/done"
rsh "$NN_NODE" "hdfs dfs -chmod 1777 /tmp /mr-history/tmp /mr-history/done"

echo "запускаем yarn"
if ! rsh "$NN_NODE" "jps | grep -qw ResourceManager"; then
    rsh "$NN_NODE" "start-yarn.sh"
fi

echo "Запуск jobhistory server"
if ! rsh "$NN_NODE" "jps | grep -qw JobHistoryServer"; then
    rsh "$NN_NODE" "mapred --daemon start historyserver"
fi

echo "node manager"
for i in $(seq 1 30); do
    n=$(rsh "$NN_NODE" "yarn node -list 2>/dev/null | grep -c RUNNING" || true)
    [ "${n:-0}" -ge 3 ] && break
    sleep 5
done
echo "NodeManager в состоянии running: ${n:-0}"

echo "Ставим nginx на edge"
sudo apt update
if [ -n "$UI_PASSWORD" ]; then
    sudo apt install -y nginx apache2-utils
else
    sudo apt install -y nginx
fi

sudo mkdir -p /etc/nginx/hadoop-ui

{
    echo 'proxy_http_version 1.1;'
    echo 'proxy_set_header Accept-Encoding "";'
    echo 'sub_filter_once off;'
    echo 'sub_filter_types text/html text/css text/plain application/json application/javascript text/javascript;'
    for ui in "${UIS[@]}"; do
        read -r ext host ip port label <<< "$ui"
        echo "sub_filter '${host}:${port}' '\$host:${ext}';"
        echo "sub_filter '${ip}:${port}' '\$host:${ext}';"
        echo "proxy_redirect http://${host}:${port}/ http://\$host:${ext}/;"
        echo "proxy_redirect http://${ip}:${port}/ http://\$host:${ext}/;"
    done
    if [ -n "$UI_PASSWORD" ]; then
        echo 'auth_basic "Hadoop UI";'
        echo 'auth_basic_user_file /etc/nginx/hadoop-ui/htpasswd;'
    fi
} | sudo tee /etc/nginx/hadoop-ui/rewrite.conf > /dev/null

if [ -n "$UI_PASSWORD" ]; then
    sudo htpasswd -bc /etc/nginx/hadoop-ui/htpasswd "$UI_USER" "$UI_PASSWORD"
fi

NGINX_CONF=""
for ui in "${UIS[@]}"; do
    read -r ext host ip port label <<< "$ui"
    NGINX_CONF+="# ${label}
server {
    listen ${ext};
    listen [::]:${ext};
    location / {
        proxy_pass http://${host}:${port};
        include /etc/nginx/hadoop-ui/rewrite.conf;
    }
}
"
done
printf '%s' "$NGINX_CONF" | sudo tee /etc/nginx/conf.d/hadoop-ui.conf > /dev/null

LINKS=""
for ui in "${UIS[@]}"; do
    read -r ext host ip port label <<< "$ui"
    LINKS+="<li><a data-port=\"${ext}\">${label}</a> (порт ${ext})</li>
"
done
sudo tee /var/www/html/index.html > /dev/null << EOF
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="utf-8"><title>Hadoop cluster team-10</title></head>
<body>
<h1>Hadoop cluster team-10: веб-интерфейсы</h1>
<ul>
${LINKS}</ul>
<script>
document.querySelectorAll('a[data-port]').forEach(function (a) {
    a.href = 'http://' + location.hostname + ':' + a.dataset.port + '/';
});
</script>
</body>
</html>
EOF

if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    for ui in "${UIS[@]}"; do
        read -r ext rest <<< "$ui"
        sudo ufw allow "${ext}/tcp"
    done
    sudo ufw allow 80/tcp
fi

sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

rsh "$NN_NODE" "hadoop jar ${HADOOP_HOME}/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.0.jar pi 2 10"

for node in "${WORKERS[@]}"; do
    echo "--- jps на ${node} ---"
    rsh "$node" "jps"
done

echo "yarn node -list"
rsh "$NN_NODE" "yarn node -list"

echo "HTTP-коды интерфейсов через nginx на edge"
CURL_AUTH=()
[ -n "$UI_PASSWORD" ] && CURL_AUTH=(-u "${UI_USER}:${UI_PASSWORD}")
for ui in "${UIS[@]}"; do
    read -r ext host ip port label <<< "$ui"
    code=$(curl -s -L "${CURL_AUTH[@]}" -o /dev/null -w "%{http_code}" "http://localhost:${ext}/" || true)
    printf '%-6s %-35s HTTP %s\n' "$ext" "$label" "$code"
done
