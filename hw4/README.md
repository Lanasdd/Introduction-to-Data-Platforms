# Домашнее задание №4

Скрипт `hw4.sh` разворачивает Apache Spark на кластере из предыдущих заданий, запускает PySpark-задачу под управлением YARN, которая читает таблицу `hw3.sales` из HDFS, трансформирует данные, сохраняет результат как партиционированную таблицу `hw4.sales_agg` и проверяет её чтение через стандартный клиент Hive (`beeline`).

## Окружение

| Компонент | Версия / значение |
|---|---|
| Hadoop (HDFS + YARN) | 3.4.0, `/home/team/hadoop-3.4.0` |
| Hive (Metastore + HiveServer2) | 4.0.0-alpha-2, `/home/team/apache-hive-4.0.0-alpha-2-bin` |
| Spark | 3.5.1 (`spark-3.5.1-bin-hadoop3`), `/home/team/spark-3.5.1-bin-hadoop3` |
| NameNode / ResourceManager | `team-10-nn` |
| Edge node (Hive, Spark, запуск скрипта) | `team-10-en` |
| HiveServer2 JDBC | `jdbc:hive2://team-10-en:10000` |
| Metastore | `thrift://team-10-en:9083`, PostgreSQL |

## Запуск

```bash
ssh team@team-10-en
chmod +x hw4.sh
./hw4.sh
```

## Что делает скрипт

1. **Поднимает HDFS и YARN** на `team-10-nn` (`start-dfs.sh`, `start-yarn.sh`), если NameNode и ResourceManager ещё не работают, и ждёт выхода HDFS из safe mode.
2. **Поднимает Hive Metastore и HiveServer2** на edge node и ждёт открытия портов 9083 и 10000.
3. **Устанавливает Spark 3.5.1** в `/home/team`, добавляет `SPARK_HOME` и `PATH` в `~/.profile`.
4. **Настраивает Spark** (`conf/spark-env.sh`):
   - `HADOOP_CONF_DIR` и `YARN_CONF_DIR` указывают на конфиги Hadoop, благодаря чему Spark находит HDFS и ResourceManager;
   - `SPARK_DIST_CLASSPATH` берётся из `hadoop classpath`;
   - в `conf/` копируется `hive-site.xml`, чтобы Spark работал с тем же Metastore, что и Hive;
   - в `jars/` копируется JDBC-драйвер PostgreSQL.
5. **Создаёт staging-директорию** `hdfs:///tmp/spark-staging` для файлов приложения YARN.
6. **Проверяет наличие исходной таблицы** `hw3.sales` через `beeline`.
7. **Генерирует PySpark-задачу** `/home/team/spark_hw4.py` и **запускает её через `spark-submit --master yarn`**.
8. **Проверяет результат** через `beeline` и выводит список партиций в HDFS.

## Структура результата

Таблица `hw4.sales_agg`:

| Колонка | Тип | Описание |
|---|---|---|
| `city` | string | город |
| `total_amount` | double | сумма продаж |
| `sales_count` | bigint | количество продаж |
| `avg_amount` | double | средняя сумма продажи |
| `sale_year` | int | год, **ключ партиции** |

Данные в HDFS разложены по партициям:

```
/user/hive/warehouse/hw4.db/sales_agg/sale_year=2022/
/user/hive/warehouse/hw4.db/sales_agg/sale_year=2023/
...
```

## Ручная проверка

Таблица читается через Hive:

```bash
beeline -u jdbc:hive2://team-10-en:10000 -n team
```

```sql
SELECT * FROM hw4.sales_agg ORDER BY sale_year, city LIMIT 10;
```

Партиции в HDFS:

```bash
hdfs dfs -ls /user/hive/warehouse/hw4.db/sales_agg
```
