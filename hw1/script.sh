#!/bin/bash
set -e

HADOOP_DIR="hadoop-3.4.0"
# ключ с edge на внутренние узлы
SSH_KEY="$HOME/.ssh/team_internal"
HADOOP_HOME="/home/team/${HADOOP_DIR}"
HDFS_DATA="/home/team/hdfs-data"
DATA_NODES=("team-10-nn" "team-10-00" "team-10-01")
NN_NODE="team-10-nn"
EDGE_NODE="team-10-en"

sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-11-jdk wget

JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
echo "JAVA_HOME=$JAVA_HOME"

# генерируем ssh-ключ на namenode без passphrase
# start-dfs.sh запускается на namenode, поэтому ключ нужен именно там
ssh -i "$SSH_KEY" team@"$NN_NODE" \
    'if [ ! -f ~/.ssh/id_ed25519 ]; then ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q; fi'

# теперь раздаем публичный ключ namenode на все узлы
for node in "${DATA_NODES[@]}"; do
    ssh -i "$SSH_KEY" team@"$NN_NODE" "cat ~/.ssh/id_ed25519.pub" | ssh -i "$SSH_KEY" team@"$node" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys"
done

# hadoop на все узлы устанавливаем 
for node in "${DATA_NODES[@]}" "$EDGE_NODE"; do
    ssh -i "$SSH_KEY" team@"$node" "bash -s" << 'EOF'
        # комментируем 127.0.1.1 в hosts, иначе namenode будет слушать только сам себя
        sudo sed -i 's/^127.0.1.1/#127.0.1.1/' /etc/hosts
        sudo apt update
        sudo apt install -y openjdk-11-jdk wget
        J=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
        if [ ! -d "hadoop-3.4.0" ]; then
            wget -q https://archive.apache.org/dist/hadoop/common/hadoop-3.4.0/hadoop-3.4.0.tar.gz
            tar -xzf hadoop-3.4.0.tar.gz
            rm hadoop-3.4.0.tar.gz
        fi
EOF
done

# прописываем переменные в profile
for node in "${DATA_NODES[@]}" "$EDGE_NODE"; do
    ssh -i "$SSH_KEY" team@"$node" "bash -s" << 'EOF'
        if ! grep -q "HADOOP_HOME" ~/.profile; then
            J=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
            echo 'export HADOOP_HOME=/home/team/hadoop-3.4.0' >> ~/.profile
            echo "export JAVA_HOME=$J" >> ~/.profile
            echo 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin' >> ~/.profile
        fi
        source ~/.profile
EOF
done

# переходим в папку с конфигами
cd /home/team/${HADOOP_DIR}/etc/hadoop/ || exit

grep -q '^export JAVA_HOME' hadoop-env.sh || echo "export JAVA_HOME=${JAVA_HOME}" >> hadoop-env.sh
grep -q '^export HDFS_NAMENODE_USER' hadoop-env.sh || cat >> hadoop-env.sh << 'EOF'
export HDFS_NAMENODE_USER=team
export HDFS_DATANODE_USER=team
export HDFS_SECONDARYNAMENODE_USER=team
EOF

# core-site.xml
cat << 'EOF' > core-site.xml
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://team-10-nn:9000</value>
    </property>
</configuration>
EOF

# hdfs-site.xml
cat << 'EOF' > hdfs-site.xml
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>3</value>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>file:///home/team/hdfs-data/namenode</value>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>file:///home/team/hdfs-data/datanode</value>
    </property>
    <property>
        <name>dfs.namenode.checkpoint.dir</name>
        <value>file:///home/team/hdfs-data/checkpoint</value>
    </property>
    <property>
        <name>dfs.namenode.secondary.http-address</name>
        <value>team-10-nn:9868</value>
    </property>
</configuration>
EOF

cat << 'EOF' > workers
team-10-nn
team-10-00
team-10-01
EOF

for node in "${DATA_NODES[@]}"; do
    ssh -i "$SSH_KEY" team@"$node" "mkdir -p /home/team/hdfs-data/{namenode,datanode,checkpoint}"
    scp -i "$SSH_KEY" \
        hadoop-env.sh core-site.xml hdfs-site.xml workers \
        team@"$node":/home/team/${HADOOP_DIR}/etc/hadoop/
done

ssh -i "$SSH_KEY" team@"$NN_NODE" "bash -s" << 'EOF'
    source ~/.profile
    if [ ! -d /home/team/hdfs-data/namenode/current ]; then
        hdfs namenode -format -nonInteractive
    fi
EOF

ssh -i "$SSH_KEY" team@"$NN_NODE" "source ~/.profile && start-dfs.sh"

for node in "${DATA_NODES[@]}"; do
    ssh -i "$SSH_KEY" team@"$node" "source ~/.profile && jps"
done