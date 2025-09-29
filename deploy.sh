#!/bin/bash
set -e

# ---------------- Colors ----------------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ---------------- ENV ----------------
ENV_FILE=".env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Файл .env не найден по пути $ENV_FILE ❌${RESET}"
    exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

required_vars=(
    NEW_USER
    PUBKEY
    FRONT_END_DOMAIN
    SUB_PUBLIC_DOMAIN
    WILDCARD_DOMAIN
    EMAIL
    TRUSTED_IP
    APP_PORT
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Не задана обязательная переменная $var в $ENV_FILE${RESET}"
        exit 1
    fi
done

echo -e "${GREEN}✅ Файл .env найден и все обязательные переменные заданы ✅${RESET}"

# ---------------- Root Check ----------------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌Скрипт должен быть запущен от root пользователя!${RESET}"
    exit 1
fi

SERVER_IP=$(curl -s https://ipinfo.io/ip)

# ---------------- OS Detection ----------------
detect_os() {
    OS=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    OS_VER=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
}

# ---------------- Dependency Check ----------------
check_dependencies() {
    dependencies=(sudo curl docker ufw ssh-keygen openssl nload tmux neovim curl wget sudo sysbench)
    MISSING=()
    for cmd in "${dependencies[@]}"; do
        if ! command -v $cmd >/dev/null 2>&1; then
            MISSING+=($cmd)
        fi
    done

    if [ ${#MISSING[@]} -ne 0 ]; then
        echo -e "${YELLOW}⚠️ Отсутствуют зависимости: ${MISSING[*]} ⚠️${RESET}"
        read -p "Установить отсутствующие пакеты? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            detect_and_update_package_manager
            for pkg in "${MISSING[@]}"; do
                install_package $pkg
            done
        else
            echo -e "${RED}⚠️ Не все зависимости установлены. Скрипт завершает работу. ⚠️${RESET}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ Все зависимости установлены ✅${RESET}"
    fi
}

# ---------------- Package Manager ----------------
detect_and_update_package_manager() {
    [ -z "$OS" ] && detect_os
    case "$OS" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            $PKG_MANAGER update -qq
            $PKG_MANAGER upgrade -y -qq
            ;;
        centos|almalinux)
            PKG_MANAGER="yum"
            $PKG_MANAGER update -y -q
            $PKG_MANAGER install -y -q epel-release
            ;;
        amzn)
            PKG_MANAGER="yum"
            $PKG_MANAGER update -y -q
            amazon-linux-extras enable epel >/dev/null 2>&1 || true
            ;;
        fedora)
            PKG_MANAGER="dnf"
            $PKG_MANAGER upgrade -y -q
            ;;
        arch)
            PKG_MANAGER="pacman"
            $PKG_MANAGER -Syu --noconfirm --quiet
            ;;
        opensuse*)
            PKG_MANAGER="zypper"
            $PKG_MANAGER refresh --quiet
            $PKG_MANAGER update -y --quiet
            ;;
        *)
            echo -e "${RED}Unsupported operating system: $OS${RESET}"
            exit 1
            ;;
    esac
}

install_package() {
    [ -z "$PKG_MANAGER" ] && detect_and_update_package_manager
    $PKG_MANAGER install -y "$1" >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ Пакет $1 установлен${RESET}"
}

# ---------------- User & SSH ----------------
basic_authentication() {
    if ! getent passwd "$NEW_USER" >/dev/null 2>&1; then
        useradd -m "$NEW_USER"
        echo -e "${GREEN}Пользователь ${NEW_USER} создан 👤${RESET}"
    else
        echo -e "${YELLOW}Пользователь ${NEW_USER} уже существует ⚠️${RESET}"
    fi

    id -nG "$NEW_USER" | grep -qw "sudo" || usermod -aG sudo "$NEW_USER"

    USER_HOME=$(eval echo "~$NEW_USER")
    mkdir -p "$USER_HOME/.ssh"
    touch "$USER_HOME/.ssh/authorized_keys"

    if [ -z "$PUBKEY" ]; then
        echo -e "${YELLOW}SSH ключ не задан. Генерируем автоматически...${RESET}"
        ssh-keygen -t ed25519 -f "$USER_HOME/.ssh/id_ed25519" -N ""
        PUBKEY=$(cat "$USER_HOME/.ssh/id_ed25519.pub")
        echo "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
        sed -i "s/^PUBKEY=.*/PUBKEY=${PUBKEY}/" .env
    else
        grep -Fxq "$PUBKEY" "$USER_HOME/.ssh/authorized_keys" || echo "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
    fi

    chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    echo -e "${GREEN}✅ SSH ключ настроен для ${NEW_USER}${RESET}"

    echo "Введите пароль для ${NEW_USER}:"
    passwd "$NEW_USER"

    sed -i "s/^#\?PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication no/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart sshd
}

# ---------------- Docker ----------------
install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Устанавливаем Docker...${RESET}"
        curl -fsSL https://get.docker.com -o install-docker.sh
        sh install-docker.sh >/dev/null 2>&1
    fi
    id -nG "$NEW_USER" | grep -qw "docker" || usermod -aG docker "$NEW_USER"
    systemctl enable --now docker
    echo -e "${GREEN}✅ Docker готов 🐳${RESET}"
}

# ---------------- Firewall ----------------
configure_firewall() {
    [ -z "$OS" ] && detect_os
    if [[ "$OS" = "ubuntu" || "$OS" = "debian" ]]; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw allow "$APP_PORT"
        ufw allow 443
        ufw --force enable
        echo -e "${GREEN}✅ Firewall настроен 🔥${RESET}"
    else
        echo -e "${RED}⚠️ Поддерживается только Ubuntu & Debian${RESET}"
    fi
}

# ---------------- Node & Panel ----------------
install_node_panel() {
    mkdir -p /opt/remnawave && cd /opt/remnawave || exit 1

    echo "Выберите что установить:"
    echo "1) Нода"
    echo "2) Панель"
    read -p "Введите номер: " choice

    case $choice in
        1)
            curl -fsSL -o compose.yml https://raw.githubusercontent.com/remnawave/node/refs/heads/main/docker-compose-prod.yml
            curl -fsSL -o .env https://raw.githubusercontent.com/remnawave/node/refs/heads/main/.env.sample
            ;;
        2)
            curl -fsSL -o compose.yml https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
            curl -fsSL -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
            ;;
        *)
            echo -e "${RED}⚠️ Некорректный выбор${RESET}"
            return
            ;;
    esac

    read -p "Введите порт для APP_PORT: " APP_PORT
    sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" .env
    echo -e "${GREEN}✅ Установка завершена. Проверьте .env и docker-compose.yml 🛠️${RESET}"
}

# ---------------- Info ----------------
show_info() {
    SERVER_IP=$(curl -s https://ipinfo.io/ip)
    GEO=$(curl -s https://ipinfo.io/$SERVER_IP | grep -E '"city"| "region"| "country"' | tr -d '{},"' | tr '\n' ' ')
    echo -e "${CYAN}🌐 Информация о системе:${RESET}"
    echo -e "OS: $OS $OS_VER ($ARCH)"
    echo -e "IP: $SERVER_IP"
    echo -e "GEO: $GEO"
    echo -e "Docker: $(docker --version 2>/dev/null || echo '⚠️ Не установлен')"
    echo -e "Пользователь: $NEW_USER ($(id -nG $NEW_USER 2>/dev/null || echo '⚠️ не существует'))"
}

# ---------------- Check scripts ----------------
check_scripts() {
    echo -e "⚡ Запуск тестов производительности и проверки сети ⚡"

    echo -e "🌐 Speedtest до RU серверов..."
    wget -qO- speedtest.artydev.ru | bash

    echo -e "🌐 Speedtest до зарубежный серверов..."
    wget -qO- bench.sh | bash

    echo -e "💻 Bench CPU..."
    sysbench cpu run

    echo -e "📍 Проверяет IP по разным геобазам, выявляет наличие в спам-реестрах, а также оценивает доступность ключевых интернет-сервисов...."
    bash <(curl -Ls ip.check.place) -l en
    bash <(curl -s storage.umager.ru/ipregion.sh)

    echo -e "🔍 Проверка доступности до Запрещеннограмма..."
    bash <(curl -s storage.umager.ru/checker_inst_ru.sh)

    echo -e "🔍 Проверка доступности до Запрещеннограмма..."
    bash <(curl -s storage.umager.ru/checker_all_ru.sh)

    echo -e "📺 Проверка YouTube..."
    bash <(curl -s storage.umager.ru/yt.sh)

    echo -e "✅ Все проверки завершены!"
}

# ---------------- Menu ----------------
show_menu() {
    while true; do
        echo -e "\n${BLUE}=== Меню установки Remnawave ===${RESET}"
        echo "1) 🛠️ Настроить пользователя и SSH"
        echo "2) ⬆️ Установить Docker"
        echo "3) ⬆️ Настроить Firewall"
        echo "4) ⬆️ Установить Ноду/Панель"
        echo "5) 📊 Показать информацию о сервере"
        echo "6) 📊 Проверить сервер в базах, доступность и пр"
        echo "0) Выход"
        read -p "Выберите действие: " option

        case $option in
            1) basic_authentication ;;
            2) install_docker ;;
            3) configure_firewall ;;
            4) install_node_panel ;;
            5) show_info ;;
            6) check_scripts ;;
            0) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}⚠️ Некорректный выбор${RESET}" ;;
        esac
    done
}

# ---------------- Run ----------------
check_dependencies
show_menu
