#!/usr/bin/env bash

# ============================================================
# Скрипт резервного копирования PostgreSQL
# Описание: создаёт сжатые gzip дампы всех пользовательских БД,
#           проверяет целостность и сохраняет в /backups
# ============================================================

# ------------------------- Конфигурация -------------------------
LOG_FILE="/var/log/pg_backup.log"          # Файл лога
BACKUP_DIR="/backups"                      # Целевая директория для бэкапов
TEMP_BASE="/tmp/pg_backup_$$"              # Временная директория ($$ - PID)
DATE_FORMAT="%Y%m%d_%H%M%S"                # Формат даты в имени файла
MIN_FREE_SPACE_BACKUP_MB=1024              # Минимально свободно в BACKUP_DIR (МБ)
MIN_FREE_SPACE_TEMP_MB=500                 # Минимально свободно во временной папке (МБ)

# Параметры подключения к PostgreSQL
# Используем .pgpass
PGHOST=192.168.1.241
PGPORT=5432
PGUSER=postgres

# Базы данных, которые НЕ нужно бэкапить
SKIP_DBS="template0 template1"

# ---------------------- Начало скрипта -------------------------

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Функция очистки временной директории
cleanup() {
    if [[ -d "$TEMP_BASE" ]]; then
        log "INFO" "Удаление временной директории $TEMP_BASE"
        rm -rf "$TEMP_BASE"
    fi
}

# Установка trap на выход и сигналы
trap cleanup EXIT INT TERM

# Проверка наличия необходимых утилит
check_requirements() {
    local required_cmds=("pg_dump" "psql" "gzip" "gunzip" "mkdir" "mv" "rm" "date")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "ERROR" "Утилита $cmd не найдена в системе. Установите её и повторите попытку."
            exit 1
        fi
    done
}

# Проверка свободного места в директории
check_free_space() {
    local dir="$1"
    local min_mb="$2"
    local dir_name="$3"

    if [[ ! -d "$dir" ]]; then
        log "ERROR" "Директория $dir не существует или недоступна."
        return 1
    fi

    local free_kb=$(df --output=avail "$dir" 2>/dev/null | tail -n1)
    if [[ -z "$free_kb" ]]; then
        log "ERROR" "Не удалось определить свободное место в $dir"
        return 1
    fi

    local free_mb=$((free_kb / 1024))
    if [[ $free_mb -lt "$min_mb" ]]; then
        log "ERROR" "Недостаточно свободного места в $dir_name: доступно ${free_mb} МБ, требуется минимум ${min_mb} МБ."
        return 1
    fi
    log "INFO" "Свободного места в $dir_name: ${free_mb} МБ (норма: >=${min_mb} МБ)"
    return 0
}

# Проверка доступности PostgreSQL
check_postgres() {
    log "INFO" "Проверка подключения к PostgreSQL ($PGHOST:$PGPORT, пользователь $PGUSER) через .pgpass"
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "SELECT 1" &>/dev/null; then
        log "ERROR" "Не удалось подключиться к PostgreSQL. Проверьте .pgpass и параметры подключения."
        return 1
    fi
    log "INFO" "Подключение к PostgreSQL успешно (аутентификация через .pgpass)"
    return 0
}

# Получение списка баз данных для бэкапа (исключая системные)
get_database_list() {
    local skip_pattern=$(echo "$SKIP_DBS" | tr ' ' '|')
    local dbs=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null)

    if [[ -z "$dbs" ]]; then
        log "ERROR" "Не удалось получить список баз данных или он пуст."
        return 1
    fi

    # Исключаем базы из SKIP_DBS
    local filtered=()
    while IFS= read -r db; do
        if [[ -n "$db" ]] && ! echo "$db" | grep -E -w "$skip_pattern" &>/dev/null; then
            filtered+=("$db")
        fi
    done <<< "$dbs"

    echo "${filtered[@]}"
}

# Основная функция бэкапа одной базы
backup_single_db() {
    local db_name="$1"
    local temp_dir="$2"
    local archive_name="${db_name}_$(date +"$DATE_FORMAT").sql.gz"
    local temp_archive="${temp_dir}/${archive_name}"
    local final_archive="${BACKUP_DIR}/${archive_name}"

    log "INFO" "Начало создания бэкапа для базы данных: $db_name"

    # 1. Дамп + сжатие
    if ! pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db_name" | gzip > "$temp_archive"; then
        log "ERROR" "Ошибка при создании дампа базы $db_name (неверный пароль/отсутствие базы/сбой)"
        return 1
    fi

    # Проверяем, что архив создался и не пуст
    if [[ ! -s "$temp_archive" ]]; then
        log "ERROR" "Созданный архив $archive_name пуст или отсутствует"
        rm -f "$temp_archive"
        return 1
    fi
    log "INFO" "Дамп базы $db_name успешно создан и сжат: $(du -h "$temp_archive" | cut -f1)"

    # 2. Проверка целостности архива
    if ! gunzip -t "$temp_archive" 2>/dev/null; then
        log "ERROR" "Проверка целостности архива $archive_name не пройдена. Архив повреждён."
        rm -f "$temp_archive"
        return 1
    fi
    log "INFO" "Проверка целостности архива $archive_name успешна"

    # 3. Перемещение в BACKUP_DIR
    if ! mv "$temp_archive" "$final_archive"; then
        log "ERROR" "Не удалось переместить архив $archive_name в $BACKUP_DIR (возможно, нет прав или места)"
        rm -f "$temp_archive"  # на всякий случай
        return 1
    fi
    log "INFO" "Архив $archive_name успешно перемещён в $BACKUP_DIR"

    return 0
}

# ---------------------- Основной поток -------------------------
main() {
    log "INFO" "================== НАЧАЛО РАБОТЫ СКРИПТА БЭКАПА =================="

    # Проверка утилит
    check_requirements

    # Создание временной директории
    mkdir -p "$TEMP_BASE" || {
        log "ERROR" "Не удалось создать временную директорию $TEMP_BASE"
        exit 1
    }
    log "INFO" "Создана временная директория: $TEMP_BASE"

    # Проверка свободного места в BACKUP_DIR и временной директории
    check_free_space "$BACKUP_DIR" "$MIN_FREE_SPACE_BACKUP_MB" "$BACKUP_DIR" || exit 1
    check_free_space "$TEMP_BASE" "$MIN_FREE_SPACE_TEMP_MB" "временной директории" || exit 1

    # Проверка возможности записи в BACKUP_DIR (создаём тестовый файл)
    if ! touch "$BACKUP_DIR/.write_test" 2>/dev/null; then
        log "ERROR" "Нет прав на запись в каталог $BACKUP_DIR"
        exit 1
    fi
    rm -f "$BACKUP_DIR/.write_test"
    log "INFO" "Права на запись в $BACKUP_DIR подтверждены"

    # Проверка доступности PostgreSQL
    check_postgres || exit 1

    # Получить список баз данных
    dbs=$(get_database_list)
    if [[ $? -ne 0 || -z "$dbs" ]]; then
        log "ERROR" "Список баз данных пуст или не удалось его получить. Скрипт завершён."
        exit 1
    fi
    log "INFO" "Найдены базы данных для бэкапа: $dbs"

    # Переменная для подсчёта успешных/неудачных бэкапов
    success_count=0
    fail_count=0

    # Цикл по базам данных
    for db in $dbs; do
        if backup_single_db "$db" "$TEMP_BASE"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    # Итоговое логирование
    log "INFO" "================== РЕЗУЛЬТАТЫ РАБОТЫ =================="
    log "INFO" "Успешно создано бэкапов: $success_count"
    if [[ $fail_count -gt 0 ]]; then
        log "ERROR" "Не удалось создать бэкапов: $fail_count"
    else
        log "INFO" "Все бэкапы созданы успешно."
    fi
    log "INFO" "Временная директория $TEMP_BASE будет удалена при выходе"
}

# Запуск основной функции
main

exit 0
