#!/bin/bash
set -e

HADOOP_DIR="hadoop-3.4.0"
HADOOP_HOME="/home/team/${HADOOP_DIR}"

HIVE_VERSION="4.0.0-alpha-2"
HIVE_DIR="apache-hive-${HIVE_VERSION}-bin"
HIVE_HOME="/home/team/${HIVE_DIR}"

SPARK_VERSION="3.5.1"
HADOOP_SPARK="hadoop3"
SPARK_DIR="spark-${SPARK_VERSION}-bin-${HADOOP_SPARK}"
SPARK_HOME="/home/team/${SPARK_DIR}"
PYSPARK_JOB="/home/team/spark_hw4.py"
SPARK_STAGING="hdfs:///tmp/spark-staging"

SSH_KEY="$HOME/.ssh/team_internal"
NN_NODE="team-10-nn"
EDGE_NODE="team-10-en"
JDBC_URL="jdbc:hive2://team-10-en:10000"

rsh() {
    local node="$1"; shift
    ssh -i "$SSH_KEY" team@"$node" "source ~/.profile && $*"
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

echo "hive metastore и hiveserver2"
mkdir -p ~/hive-logs
if ! pgrep -f HiveMetaStore > /dev/null; then
    nohup hive --service metastore > ~/hive-logs/metastore.log 2>&1 &
fi
wait_port 9083
if ! pgrep -f HiveServer2 > /dev/null; then
    nohup hive --service hiveserver2 > ~/hive-logs/hiveserver2.log 2>&1 &
fi
wait_port 10000

echo "apache spark"
cd ~
if [ ! -d "$SPARK_HOME" ]; then
    wget -q "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_DIR}.tgz"
    tar -xzf "${SPARK_DIR}.tgz"
    rm -f "${SPARK_DIR}.tgz"
fi

if ! grep -q "SPARK_HOME" ~/.profile; then
    echo "export SPARK_HOME=${SPARK_HOME}" >> ~/.profile
    echo 'export PATH=$PATH:$SPARK_HOME/bin' >> ~/.profile
fi
source ~/.profile

echo "spark-env.sh"
cat > "$SPARK_HOME/conf/spark-env.sh" <<EOF
export JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
export HADOOP_HOME=${HADOOP_HOME}
export HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
export YARN_CONF_DIR=${HADOOP_HOME}/etc/hadoop
export HIVE_HOME=${HIVE_HOME}
export SPARK_DIST_CLASSPATH=\$(${HADOOP_HOME}/bin/hadoop classpath)
export PYSPARK_PYTHON=python3
EOF

cp "${HIVE_HOME}/conf/hive-site.xml" "${SPARK_HOME}/conf/"
cp "${HIVE_HOME}/lib/postgresql-42.7.4.jar" "${SPARK_HOME}/jars/" 2>/dev/null || true

hdfs dfs -mkdir -p "$SPARK_STAGING"
hdfs dfs -chmod 1777 "$SPARK_STAGING" 2>/dev/null || true

echo "проверка hw3.sales"
beeline -u "$JDBC_URL" -n team --silent=true -e "SHOW TABLES IN hw3 LIKE 'sales'" \
    | grep -qw sales || { echo "нет hw3.sales" >&2; exit 1; }

echo "spark_hw4.py"
cat > "$PYSPARK_JOB" <<'PY'
from pyspark.sql import SparkSession, functions as F

spark = SparkSession.builder.appName("HW4_Spark_YARN_Hive").enableHiveSupport().getOrCreate()
spark.sparkContext.setLogLevel("WARN")
df = spark.sql("SELECT * FROM hw3.sales")
df.printSchema()

df_transform = (df.withColumn("sale_year", F.col("sale_year").cast("int"))
    .withColumn("amount", F.col("amount").cast("double"))
    .withColumn("city", F.col("city").cast("string"))
    .filter(F.col("amount") > 0)
    .filter(F.col("sale_year").isNotNull()))

df_agg = df_transform.groupBy("sale_year", "city").agg(
    F.sum("amount").alias("total_amount"),
    F.count("*").alias("sales_count"),
    F.avg("amount").alias("avg_amount"),
)
print("результат агрегации")
df_agg.show(10, truncate=False)

spark.sql("CREATE DATABASE IF NOT EXISTS hw4")
(df_agg.write.mode("overwrite").format("orc").partitionBy("sale_year").saveAsTable("hw4.sales_agg"))
print("создана таблица hw4.sales_agg")

spark.sql("SELECT * FROM hw4.sales_agg ORDER BY sale_year, city LIMIT 10").show(truncate=False)
spark.stop()
PY

echo "spark-submit"
"$SPARK_HOME/bin/spark-submit" \
    --master yarn \
    --deploy-mode client \
    --driver-memory 1g \
    --executor-memory 1g \
    --executor-cores 1 \
    --num-executors 2 \
    --conf spark.sql.warehouse.dir=hdfs:///user/hive/warehouse \
    --conf spark.yarn.stagingDir="$SPARK_STAGING" \
    --conf spark.sql.shuffle.partitions=2 \
    "$PYSPARK_JOB"

echo "проверка через beeline"
beeline -u "$JDBC_URL" -n team \
    -e "SELECT * FROM hw4.sales_agg ORDER BY sale_year, city LIMIT 10"

echo "партиции в hdfs"
rsh "$NN_NODE" "hdfs dfs -ls /user/hive/warehouse/hw4.db/sales_agg"