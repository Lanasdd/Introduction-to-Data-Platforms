# Домашнее задание №5

Процесс обработки данных реализован в виде потока Prefect (`hw5_prefect.py`). Поток поднимает кластер из предыдущих заданий, запускает Spark-сессию под управлением YARN, читает из HDFS таблицу `hw3.sales`, загруженную туда заранее, трансформирует данные и сохраняет результат как партиционированную таблицу `hw4.sales_agg`. После этого он проверяет результат через стандартный клиент Hive (beeline) и смотрит файлы в HDFS.

## Окружение

| Компонент | Версия / значение |
|---|---|
| Оркестратор | Prefect 3.x (`prefect>=3`) |
| Hadoop (HDFS + YARN) | 3.4.0, `/home/team/hadoop-3.4.0` |
| Hive (Metastore + HiveServer2) | 4.0.0-alpha-2, `/home/team/apache-hive-4.0.0-alpha-2-bin` |
| Spark | 3.5.1 (spark-3.5.1-bin-hadoop3), `/home/team/spark-3.5.1-bin-hadoop3` |
| NameNode / ResourceManager | `team-10-nn` |
| Edge node (Hive, Spark, Prefect, запуск) | `team-10-en` |
| HiveServer2 JDBC | `jdbc:hive2://team-10-en:10000` |
| Metastore | `thrift://team-10-en:9083`, PostgreSQL |

## Запуск

```bash
ssh team@team-10-en
chmod +x hw5.sh hw5_cluster.sh
./hw5.sh
```

`hw5.sh` устанавливает Prefect 3 (`pip install "prefect>=3"`), а если pip отказывает из-за системного окружения, повторяет установку с `--break-system-packages`. Затем он выполняет `python3 hw5_prefect.py`. Поток запускается локально, отдельный сервер Prefect для этого не нужен.

## Структура потока

Поток `hw5` последовательно выполняет три задачи. Если какая-то из них падает, поток останавливается.

1. **`cluster_ready`** (до 2 повторов с паузой 30 с) запускает `hw5_cluster.sh`. Скрипт поднимает HDFS и YARN на `team-10-nn` и Hive Metastore с HiveServer2 на edge node, ставит Spark 3.5.1 и настраивает его на работу с YARN, HDFS и общим Metastore (`spark-env.sh`, `hive-site.xml`, драйвер PostgreSQL). Затем он создаёт staging-директорию в HDFS и проверяет, что таблица `hw3.sales` существует. Уже запущенные сервисы скрипт пропускает.
2. **`spark_submit`** запускает `hw4_spark.py` через `spark-submit --master yarn --deploy-mode client` (2 executor'а по 1 ГБ). Задача читает `hw3.sales` из HDFS, приводит типы, отфильтровывает некорректные строки и агрегирует данные по `sale_year` и `city` (`sum`, `count`, `avg` по `amount`). Результат сохраняется в таблицу `hw4.sales_agg` (ORC, партиционирование по `sale_year`).
3. **`verify`** проверяет результат: выполняет `SHOW PARTITIONS hw4.sales_agg` в beeline и `hdfs dfs -ls` по каталогу таблицы.

## Структура результата

Таблица `hw4.sales_agg`:

| Колонка | Тип | Описание |
|---|---|---|
| city | string | город |
| total_amount | double | сумма продаж |
| sales_count | bigint | количество продаж |
| avg_amount | double | средняя сумма продажи |
| sale_year | int | год, ключ партиции |

Данные в HDFS разложены по партициям:

```
/user/hive/warehouse/hw4.db/sales_agg/sale_year=2022/
/user/hive/warehouse/hw4.db/sales_agg/sale_year=2023/
...
```

## Ручная проверка

Статус выполнения потока и задач виден в консоли Prefect: в логе есть `Finished in state Completed()` для каждой задачи и для потока `hw5`.

Приложение Spark в YARN:

```bash
yarn application -list -appStates FINISHED | grep HW4_Spark_YARN_Hive
```

Таблица читается через Hive:

```bash
beeline -u jdbc:hive2://team-10-en:10000 -n team
SELECT * FROM hw4.sales_agg ORDER BY sale_year, city LIMIT 10;
```

Партиции в HDFS:

```bash
hdfs dfs -ls /user/hive/warehouse/hw4.db/sales_agg
```
