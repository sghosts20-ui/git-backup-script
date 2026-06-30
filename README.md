# Интеграция Git-бэкапа на сервер

Этот документ описывает установку и проверку серверного Git-бэкапа в текущей схеме:

- `mirror` по каждому проекту в виде bare-репозитория `*.git`
- файловые копии всех веток в `checkouts/<project>/<branch>/`
- ежедневный `bundle` для аварийного восстановления

Скрипт: `git-backup.sh`

## Что получится на сервере

После настройки структура будет такой:

```text
/STORAGE/git/backup/
  <project>.git/                 # bare mirror проекта
  bundles/
    <project>-20260630.bundle    # переносимый bundle
  checkouts/
    <project>/
      main/                      # обычная файловая копия ветки
      feature-x/                 # обычная файловая копия ветки
      dev/                       # появится автоматически, если ветка есть в Git
```

## Что делает скрипт

При обычном запуске `git-backup.sh`:

1. Обновляет все `mirror`-репозитории в `BACKUP_ROOT`
2. Читает все ветки из каждого `mirror`
3. Создаёт или обновляет файловую копию каждой ветки в `checkouts`
4. Создаёт bundle за текущую дату
5. Удаляет старые bundle по сроку хранения

Новые ветки подхватываются автоматически на следующем запуске.

## Предварительные требования

- Linux-сервер с `git`
- отдельный системный пользователь `gitbackup`
- выделенный каталог для бэкапов, например `/STORAGE/git/backup`
- доступ на чтение к удалённому Git-репозиторию
- настроенный SSH-ключ или read-only token

## 1. Установка зависимостей

Для Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y git
```

## 2. Создание пользователя и каталогов

```bash
sudo adduser --disabled-password --gecos "Git backup" gitbackup
sudo mkdir -p /STORAGE/git/backup
sudo chown gitbackup:gitbackup /STORAGE/git/backup
```

Если каталог уже существует:

```bash
sudo chown -R gitbackup:gitbackup /STORAGE/git/backup
```

## 3. Подготовка доступа к Git

Переключитесь под пользователя `gitbackup`:

```bash
sudo -u gitbackup -H bash
```

Дальше настройте доступ к вашему Git-серверу:

- либо через SSH-ключ в `~/.ssh/`
- либо через HTTPS с read-only token

Для SSH проверьте, что ключ уже работает:

```bash
ssh -T git@<git-host>
```

Если у вас read-only токен, этого достаточно: скрипт ничего не пишет на origin, он только читает удалённый репозиторий и пишет данные локально на сервер.

## 4. Размещение скрипта на сервере

Скопируйте актуальный `git-backup.sh` в:

```text
/usr/local/bin/git-backup.sh
```

Например:

```bash
sudo tee /usr/local/bin/git-backup.sh >/dev/null <<'EOF'
# сюда вставить текущее содержимое файла git-backup.sh
EOF
```

Выдайте права на исполнение:

```bash
sudo chmod +x /usr/local/bin/git-backup.sh
```

## 5. Создание лог-файла

```bash
sudo touch /var/log/git-backup.log
sudo chown gitbackup:gitbackup /var/log/git-backup.log
```

## 6. Первичная инициализация проекта

Очень важно: зеркало нужно создавать именно через `--mirror`.

Пример для проекта `<project>`:

```bash
sudo -u gitbackup -H git clone --mirror git@<git-host>:<group>/<project>.git /STORAGE/git/backup/<project>.git
```

Нельзя использовать:

```bash
git clone --bare -b main ...
```

Иначе можно случайно забрать только одну ветку.

Если проектов несколько, повторите команду для каждого проекта.

## 7. Первый ручной запуск

Запустите скрипт вручную:

```bash
sudo -u gitbackup /usr/local/bin/git-backup.sh
```

Проверьте лог:

```bash
tail /var/log/git-backup.log
```

В логе должны появиться строки вида:

```text
Mirror: OK <project> (2 branch(es): feature-x, main)
Checkout: OK <project>/main
Checkout: OK <project>/feature-x
Bundle: OK <project> (...)
```

## 8. Что проверить после первого запуска

### Проверка mirror

```bash
git -C /STORAGE/git/backup/<project>.git branch -a
ls /STORAGE/git/backup/<project>.git/refs/heads/
```

### Проверка файловых копий

```bash
ls /STORAGE/git/backup/checkouts/<project>/
```

Ожидаемо:

```text
feature-x
main
```

Если в Git появится новая ветка, например `dev`, после следующего запуска скрипта появится:

```text
/STORAGE/git/backup/checkouts/<project>/dev
```

### Проверка bundle

```bash
ls /STORAGE/git/backup/bundles/
git bundle list-heads /STORAGE/git/backup/bundles/<project>-$(date +%Y%m%d).bundle
```

## 9. Настройка cron

Откройте cron пользователя `gitbackup`:

```bash
sudo crontab -u gitbackup -e
```

Пример запуска каждые 6 часов:

```cron
0 */6 * * * /usr/local/bin/git-backup.sh
```

Если нужен запуск раз в сутки:

```cron
0 3 * * * /usr/local/bin/git-backup.sh
```

## 10. Восстановление из бэкапа

### Вариант 1. Быстро получить файлы проекта

Используйте готовую файловую копию ветки:

```bash
cp -a /STORAGE/git/backup/checkouts/<project>/main /tmp/<project>-restored
```

### Вариант 2. Восстановить весь репозиторий из mirror

```bash
git clone /STORAGE/git/backup/<project>.git /tmp/<project>-restored
cd /tmp/<project>-restored
git branch -a
```

### Вариант 3. Восстановить из bundle

```bash
git clone /STORAGE/git/backup/bundles/<project>-20260630.bundle /tmp/<project>-restored
cd /tmp/<project>-restored
git branch -a
```

## Типовые проблемы

### В `mirror` видна только одна ветка

Проверьте, как создавался репозиторий. Должно быть:

```bash
git clone --mirror ...
```

Проверьте refspec:

```bash
git -C /STORAGE/git/backup/<project>.git config --get-all remote.origin.fetch
```

Корректные варианты:

```text
+refs/*:refs/*
+refs/heads/*:refs/heads/*
```

### В `branches/` пусто

Это нормально. Смотреть нужно не в `branches/`, а в:

```text
/STORAGE/git/backup/<project>.git/refs/heads/
```

### Папка checkout уже существует, но скрипт ругается

Скрипт ожидает в `checkouts/<project>/<branch>/` полноценный git-клон. Если там лежит обычная папка, он не будет её удалять автоматически и запишет ошибку в лог.

### Bundle не обновился после появления новых веток

Скрипт умеет пересоздавать bundle, если видит, что в нём меньше refs, чем в текущем mirror. Для ручного пересоздания можно использовать:

```bash
sudo -u gitbackup env BUNDLE_FORCE=1 /usr/local/bin/git-backup.sh
```

## Чеклист интеграции

- [ ] На сервере установлен `git`
- [ ] Создан пользователь `gitbackup`
- [ ] Создан каталог `/STORAGE/git/backup`
- [ ] Права на `/STORAGE/git/backup` выданы пользователю `gitbackup`
- [ ] Настроен доступ `gitbackup` к Git-серверу по SSH или read-only token
- [ ] Скрипт `git-backup.sh` размещён в `/usr/local/bin/git-backup.sh`
- [ ] Скрипт сделан исполняемым через `chmod +x`
- [ ] Создан лог `/var/log/git-backup.log`
- [ ] Права на лог выданы пользователю `gitbackup`
- [ ] Для каждого проекта выполнен `git clone --mirror`
- [ ] Скрипт хотя бы один раз успешно запущен вручную
- [ ] В логе есть `Mirror: OK`
- [ ] В `checkouts/<project>/` появились папки веток
- [ ] В `bundles/` появился `.bundle` за текущую дату
- [ ] Настроен `cron`
- [ ] Проверено восстановление хотя бы одним способом

## Чеклист проверки после изменений

Используйте этот чеклист после правок скрипта, смены ключа, переноса сервера или добавления новых проектов:

- [ ] `sudo -u gitbackup /usr/local/bin/git-backup.sh` выполняется без ошибок
- [ ] `tail /var/log/git-backup.log` не содержит `ERROR`
- [ ] `git -C /STORAGE/git/backup/<project>.git branch -a` показывает все ожидаемые ветки
- [ ] `ls /STORAGE/git/backup/checkouts/<project>/` показывает все ожидаемые ветки как папки
- [ ] `git bundle list-heads /STORAGE/git/backup/bundles/<project>-YYYYMMDD.bundle` показывает актуальные refs

