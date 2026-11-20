from prefect import flow, task, get_run_logger
import subprocess

def sh(cmd):
    r = subprocess.run("source ~/.profile && " + cmd, shell=True, text=True, capture_output=True, executable="/bin/bash")
    get_run_logger().info(r.stdout + r.stderr)
    if r.returncode: raise RuntimeError(cmd)

@task(retries=2, retry_delay_seconds=30)
def cluster_ready():
    sh("bash /home/team/hw5_cluster.sh")

@task
def spark_submit():
    sh('/home/team/spark-3.5.1-bin-hadoop3/bin/spark-submit --master yarn --deploy-mode client '
       '--driver-memory 1g --executor-memory 1g --executor-cores 1 --num-executors 2 '
       '--conf spark.sql.warehouse.dir=hdfs:///user/hive/warehouse '
       '--conf spark.yarn.stagingDir=hdfs:///tmp/spark-staging '
       '--conf spark.sql.shuffle.partitions=2 /home/team/hw4_spark.py')

@task
def verify():
    sh('beeline -u jdbc:hive2://team-10-en:10000 -n team --silent=true -e "SHOW PARTITIONS hw4.sales_agg"')
    sh("ssh -i $HOME/.ssh/team_internal team@team-10-nn 'source ~/.profile && hdfs dfs -ls /user/hive/warehouse/hw4.db/sales_agg'")

@flow
def hw5():
    cluster_ready()
    spark_submit()
    verify()

if __name__ == "__main__":
    hw5()