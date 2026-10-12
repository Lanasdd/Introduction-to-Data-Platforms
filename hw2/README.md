# Домашнее задание №2: Развертывание YARN и публикация веб-интерфейсов

Скрипт `script.sh` разворачивает YARN поверх кластера HDFS (ДЗ №1) и публикует
веб-интерфейсы всех основных и вспомогательных демонов кластера для внешнего
использования через nginx на edge-узле.

## Схема кластера

| Узел | IP | Что запущено |
|------|-----|--------------|
| team-10-en | 10.10.0.10 | edge, nginx (обратный прокси), отсюда запускается скрипт |
| team-10-nn | 10.10.0.11 | NameNode, SecondaryNameNode, DataNode, ResourceManager, NodeManager, JobHistoryServer |
| team-10-00 | 10.10.0.12 | DataNode, NodeManager |
| team-10-01 | 10.10.0.13 | DataNode, NodeManager |

## Что разворачивается

### YARN

- **ResourceManager** — на `team-10-nn`
- **NodeManager** — на `team-10-nn`, `team-10-00`, `team-10-01`
- **JobHistory Server** — на `team-10-nn`
- **MapReduce** работает в режиме `yarn`

### Веб-интерфейсы

Все UI публикуются через **nginx** на edge-узле. Nginx слушает внешние порты
и проксирует запросы на внутренние узлы кластера. Внутренние адреса
(`team-10-nn:8088`, `10.10.0.11:8088` и т.п.) автоматически переписываются
в `<host>:<внешний порт>` с помощью `sub_filter`, поэтому ссылки внутри UI
работают корректно.

### Что делает скрипт

1. Проверяет, что HDFS запущен, и ждёт выхода из safemode
2. Генерирует `yarn-site.xml` и `mapred-site.xml`
3. Копирует конфиги на все четыре узла
4. Дописывает `YARN_RESOURCEMANAGER_USER` и `YARN_NODEMANAGER_USER` в `hadoop-env.sh`
5. Создаёт HDFS-каталоги `/tmp`, `/user/team`, `/mr-history/tmp`, `/mr-history/done`
6. Запускает YARN (`start-yarn.sh`) на NameNode
7. Запускает JobHistory Server (`mapred --daemon start historyserver`)
8. Ждёт, пока все 3 NodeManager перейдут в состояние `RUNNING` (до 30 попыток по 5 секунд)
9. Устанавливает и настраивает nginx на edge-узле
10. Публикует 10 веб-интерфейсов на портах edge-узла
11. Создаёт стартовую страницу на порту 80 со ссылками на все UI
12. Открывает порты в UFW (если он активен)
13. Запускает тестовую MapReduce-задачу `pi 2 10`
14. Выводит `jps` на всех worker-узлах
15. Выводит `yarn node -list`
16. Проверяет HTTP-коды всех веб-интерфейсов через nginx


## Запуск

### 1. Скопировать скрипт на edge

С локальной машины:

```bash
scp script.sh team@2.59.81.13:~/
```

### 2. Зайти на edge и открыть tmux

```bash
ssh team@2.59.81.13
tmux new -s yarn
```
### 3. Запустить скрипт

```bash
bash script.sh
```

### 4. Проверить результат

```bash
ssh -i ~/.ssh/team_internal team@team-10-nn \
  "source ~/.profile && yarn node -list"
```

Ожидается `Total Nodes:3`, все RUNNING.

### 5. Открыть веб-интерфейсы

С локальной машины:

```bash
ssh -N \
    -L 9870:localhost:9870 \
    -L 8088:localhost:8088 \
    -L 19888:localhost:19888 \
    team@2.59.81.13
```

Затем в браузере:

- http://localhost:8088 — YARN ResourceManager
- http://localhost:9870 — NameNode
- http://localhost:19888 — JobHistory
