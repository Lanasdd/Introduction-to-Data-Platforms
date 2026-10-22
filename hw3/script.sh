#!/bin/bash
set -e

HIVE_VERSION="4.0.0-alpha-2"
HIVE_DIR="apache-hive-${HIVE_VERSION}-bin"
HIVE_HOME="/home/team/${HIVE_DIR}"
PG_JDBC="postgresql-42.7.4.jar"
DB_PASSWORD="${DB_PASSWORD:-hive}"
SSH_KEY="$HOME/.ssh/team_internal"
NN_NODE="team-10-nn"
JDBC_URL="jdbc:hive2://team-10-en:10000"

rsh() {
    local node="$1"; shift
    ssh -i "$SSH_KEY" team@"$node" "source ~/.profile && $*"
}

pg() {
    (cd /tmp && sudo -u postgres psql -tAc "$1")
}

wait_port() {
    for i in $(seq 1 60); do
        (echo > /dev/tcp/localhost/"$1") 2>/dev/null && return 0
        sleep 5
    done
    echo "порт $1 не открылся"
    return 1
}

cd ~
source ~/.profile

echo "hdfs и yarn"
if ! rsh "$NN_NODE" "jps | grep -qw NameNode"; then
    rsh "$NN_NODE" "start-dfs.sh"
fi
if ! rsh "$NN_NODE" "jps | grep -qw ResourceManager"; then
    rsh "$NN_NODE" "start-yarn.sh"
fi
rsh "$NN_NODE" "hdfs dfsadmin -safemode wait"

echo "postgres"
sudo apt update
sudo apt install -y postgresql

if [ -z "$(pg "SELECT 1 FROM pg_roles WHERE rolname = 'hive'")" ]; then
    pg "CREATE USER hive WITH PASSWORD '${DB_PASSWORD}'"
fi
if [ -z "$(pg "SELECT 1 FROM pg_database WHERE datname = 'metastore'")" ]; then
    pg "CREATE DATABASE metastore OWNER hive"
fi

echo "hive"
if [ ! -d "$HIVE_HOME" ]; then
    wget -q https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_DIR}.tar.gz
    tar -xzf ${HIVE_DIR}.tar.gz
    rm ${HIVE_DIR}.tar.gz
fi
if [ ! -f "$HIVE_HOME/lib/$PG_JDBC" ]; then
    wget -q -P "$HIVE_HOME/lib" https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/${PG_JDBC}
fi

if ! grep -q "HIVE_HOME" ~/.profile; then
    echo "export HIVE_HOME=${HIVE_HOME}" >> ~/.profile
    echo 'export PATH=$PATH:$HIVE_HOME/bin' >> ~/.profile
fi
source ~/.profile

cat << EOF > "$HIVE_HOME/conf/hive-site.xml"
<configuration>
    <property>
        <name>javax.jdo.option.ConnectionURL</name>
        <value>jdbc:postgresql://localhost:5432/metastore</value>
    </property>
    <property>
        <name>javax.jdo.option.ConnectionDriverName</name>
        <value>org.postgresql.Driver</value>
    </property>
    <property>
        <name>javax.jdo.option.ConnectionUserName</name>
        <value>hive</value>
    </property>
    <property>
        <name>javax.jdo.option.ConnectionPassword</name>
        <value>${DB_PASSWORD}</value>
    </property>
    <property>
        <name>hive.metastore.uris</name>
        <value>thrift://team-10-en:9083</value>
    </property>
    <property>
        <name>hive.metastore.warehouse.dir</name>
        <value>/user/hive/warehouse</value>
    </property>
    <property>
        <name>hive.metastore.event.db.notification.api.auth</name>
        <value>false</value>
    </property>
    <property>
        <name>hive.server2.thrift.bind.host</name>
        <value>0.0.0.0</value>
    </property>
    <property>
        <name>hive.server2.thrift.port</name>
        <value>10000</value>
    </property>
    <property>
        <name>hive.server2.enable.doAs</name>
        <value>false</value>
    </property>
    <property>
        <name>hive.execution.engine</name>
        <value>mr</value>
    </property>
</configuration>
EOF

hdfs dfs -mkdir -p /user/hive/warehouse /tmp/hive /data/sales
hdfs dfs -chmod 1777 /tmp/hive

if ! schematool -dbType postgres -info > /dev/null 2>&1; then
    schematool -dbType postgres -initSchema
fi

echo "metastore и hiveserver2"
echo 'export HADOOP_HEAPSIZE=1024' > "$HIVE_HOME/conf/hive-env.sh"
mkdir -p ~/hive-logs
if ! pgrep -f HiveMetaStore > /dev/null; then
    nohup hive --service metastore > ~/hive-logs/metastore.log 2>&1 &
fi
wait_port 9083
if ! pgrep -f HiveServer2 > /dev/null; then
    nohup hive --service hiveserver2 > ~/hive-logs/hiveserver2.log 2>&1 &
fi
wait_port 10000

echo "загрузка данных"
awk 'BEGIN {
    srand(42)
    split("Moscow,Kazan,Perm,Omsk,Tver", cities, ",")
    for (i = 1; i <= 3000; i++) {
        y = 2024 + int(rand() * 3)
        m = 1 + int(rand() * 12)
        d = 1 + int(rand() * 28)
        printf "%d,%d-%02d-%02d,%s,%.2f\n", i, y, m, d, cities[1 + int(rand() * 5)], 100 + rand() * 9900
    }
}' > /tmp/sales.csv
hdfs dfs -put -f /tmp/sales.csv /data/sales/

cat << 'EOF' > /tmp/load.sql
CREATE DATABASE IF NOT EXISTS hw3;
USE hw3;

DROP TABLE IF EXISTS sales_raw;
CREATE EXTERNAL TABLE sales_raw (
    id INT,
    sale_date STRING,
    city STRING,
    amount DOUBLE
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/data/sales';

DROP TABLE IF EXISTS sales;
CREATE TABLE sales (
    id INT,
    sale_date DATE,
    city STRING,
    amount DOUBLE
)
PARTITIONED BY (sale_year INT)
STORED AS ORC;

SET hive.exec.dynamic.partition.mode=nonstrict;

INSERT OVERWRITE TABLE sales PARTITION (sale_year)
SELECT id, CAST(sale_date AS DATE), city, amount, year(CAST(sale_date AS DATE))
FROM sales_raw;

SHOW PARTITIONS sales;
EOF
beeline -u "$JDBC_URL" -n team -f /tmp/load.sql

echo "два клиента одновременно"
beeline -u "$JDBC_URL" -n team --silent=true -e "SELECT sale_year, count(*) FROM hw3.sales GROUP BY sale_year" > /tmp/client1.log 2>&1 &
c1=$!
beeline -u "$JDBC_URL" -n team --silent=true -e "SHOW PARTITIONS hw3.sales" > /tmp/client2.log 2>&1 &
c2=$!
wait $c1 $c2
cat /tmp/client1.log /tmp/client2.log
