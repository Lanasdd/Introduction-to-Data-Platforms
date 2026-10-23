# Домашнее задание №3 

Скрипт `script.sh` автоматизирует полное развертывание Apache Hive в **remote-режиме**
(metastore + HiveServer2 как отдельные сервисы), что позволяет подключаться **нескольким
клиентам одновременно**. Также реализована автоматическая загрузка данных
в **партиционированную таблицу** (партиционирование по году продаж).

## Архитектура решения

| Компонент | Узел | Назначение |
|---|---|---|
| HDFS + YARN (NameNode, ResourceManager) | `team-10-nn` | Хранение данных, MR-движок выполнения |
| PostgreSQL | локально (на узле запуска скрипта) | Внешняя БД для Hive Metastore |
| Hive Metastore (thrift :9083) | `team-10-en` | Общий каталог метаданных для всех клиентов |
| HiveServer2 (thrift :10000) | `team-10-en` | Точка входа для множества клиентов (Beeline/JDBC) |

Использование внешней СУБД (PostgreSQL) и отдельного Metastore-сервиса исключает
**embedded-режим** — несколько клиентов могут одновременно работать с одним Hive.

## Что делает скрипт (пошагово)

1. **Запуск HDFS и YARN** на `team-10-nn` (если ещё не запущены) + ожидание выхода из safemode.
2. **Установка и настройка PostgreSQL**: создание пользователя `hive` и БД `metastore`.
3. **Установка Hive 4.0.0-alpha-2** с archive.apache.org, скачивание JDBC-драйвера PostgreSQL
   в `$HIVE_HOME/lib`.
4. **Прописывание `HIVE_HOME`** в `~/.profile`.
5. **Генерация `hive-site.xml`** с подключением к PostgreSQL, указанием `hive.metastore.uris`
   и параметров HiveServer2 (bind `0.0.0.0`, порт `10000`, `doAs=false`).
6. **Создание HDFS-директорий** `/user/hive/warehouse`, `/tmp/hive`, `/data/sales`.
7. **Инициализация схемы Metastore** через `schematool` (идемпотентно).
8. **Запуск сервисов** `metastore` и `hiveserver2` в фоне + ожидание открытия портов 9083 и 10000.
9. **Генерация тестовых данных** (3000 строк CSV: `id, sale_date, city, amount`) и загрузка
   в HDFS `/data/sales`.
10. **Загрузка в Hive**: создание БД `hw3`, внешней таблицы `sales_raw` (TEXTFILE),
    партиционированной ORC-таблицы `sales` (partition by `sale_year`), динамическая вставка
    данных (`hive.exec.dynamic.partition.mode=nonstrict`).
11. **Проверка многоклиентности**: одновременный запуск двух Beeline-клиентов
    (`SELECT ... GROUP BY` и `SHOW PARTITIONS`) — оба успешно работают через общий HiveServer2.

## Требования

- Bash, доступ по SSH с ключом `~/.ssh/team_internal` к узлам `team-10-nn`, `team-10-en`.
- `sudo` для установки PostgreSQL.
- `wget`, `awk`, `beeline`, `hdfs`, `hive` в PATH (после шага 4).
- Hadoop-кластер уже сконфигурирован на узлах.


## Запуск


1. С локальной машины — скопировать скрипт на edge
   
scp script.sh team@2.59.81.13:~/

2. Зайти на edge, tmux
   
ssh team@2.59.81.13
tmux new -s hive

3. Проверить, что мы на нужном узле (metastore/HS2 поднимаются локально,
а hive.metastore.uris и JDBC_URL указывают на team-10-en)

hostname
getent hosts team-10-en

5. Запустить
   
bash script.sh

5. Проверка Hive
   
beeline -u "jdbc:hive2://team-10-en:10000" -n team -e "SHOW PARTITIONS hw3.sales"
beeline -u "jdbc:hive2://team-10-en:10000" -n team \
  -e "SELECT sale_year, count(*) FROM hw3.sales GROUP BY sale_year"
