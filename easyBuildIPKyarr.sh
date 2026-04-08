#!/bin/sh

# Этот скрипт лишь выкачивает бинарные файлы yarr, а затем делает из них установочные файлы для операционной системы OpenWRT. Автором yarr (yet another rss reader) является https://github.com/nkanaev, а это лишь скрипт, который позволяет сделать ipk файлы для установки yarr на OpenWRT через системные пакеты.

# Из существенных недоработок и недоделок отмечу, что галочка автозапуска в веб интерфейсе Luci не работает, ак как параметр autostart в LuCI JS форме не используется в этом init-скрипте, потому что управление автозапуском в OpenWrt осуществляется через enable/disable сервиса. Чтобы связать флаг autostart с реальным поведением, нужно добавить в LuCI обработчик, вызывающий /etc/init.d/yarr enable или disable. Так же при нажатии кнопки "применить изменения" в интерфейсе LuCI сами измненения хоть записываются в UCI файл настроек /etc/config/yarr, но программа не перезапускается сама, соотвественно, перезапускать сервис придётся вручную. Так же в веб интерфейсе не отображается статус работы службы, нет возможности перезапустить службу, а часть функционала вообще не реализована. Да и открытие адреса я пока сделал топорно: оно не всегда корректно умеет отслживать под каким адресом запущен yarr.
# По этой причине, при каждом изменении настроек в LuCI нужно нажать "применить", а потом перезапустить сервис командой "service yarr restart".

# Вот такой командой запускается эта служба и висит в фоне, храня данные в оперативной памяти: /tmp/yarr/yarr -addr 192.168.1.1:7070 -db /tmp/yarr/yarr.db, но вот из минусов отмечу, что удаление файла yarr.db приводит к удалению и всех подписок (а оно выполняется каждый раз при перезагрузке роутера), за то nand память не портится и не переполняется. Для постоянного использования лучше использовать внешнее хранилище, например, в разлеле /mnt/sda1/yarr/yarr.db в нём записи подписок, разумеется, не будут теряться при каждой перезагрузке.


yarrSource="yarrSource" # папка, в которой будет создаваться файловая система ipk установочника
yarrLuciSource="yarrLuciSource" # папка, в которой будет создаваться файловая система ipk установочника веб интерфейса

UPX_archive=false # Применять ли сжатие.

# Хотя по идее лучше сделать, чтобы оно на выходе создавало две папки. Первая - это с UPX сжатием файлы, а вторая - без UPX сжатия. Так будет лучше. Хотя может и лучше ipk файлы (в которых используется UPX) с другими именами создавать, чтобы вообще одним релизом всё выкладывать.
# Диалог с выбором применять ли сжатие UPX. Возможны глюки, а также приложение может медленне запускататься, однако на устройствах с малым объёмом памяти может и не быть выбора. Впрочем, я критичных глюков не ловил. Кстати, ужимается файл хоть и в 3 раза, но в памяти устройства лишь почему-то занимет на приблизительно около 1 Мб. При этом upx говорит о сжатии что-то чуть больше 30%. Вероятно, UPX или другой алгоритм сжатия уже применялся, но не такой агрессивный, хотя я не уверен.
while true; do
	read -rp "Применять ли сжатие через UPX для yarr? [Д/н]: " answer
	case "$answer" in
		""|Д|д|Да|да|Y|y|Yes|yes)
			UPX_archive=true
			break
			;;
		Н|н|Нет|нет|N|n|No|no)
			UPX_archive=false
			break
			;;
		*)
			echo "Неправильный ввод. Попробуйте еще раз."
			continue
			;;
		esac
done

# Скачивает и извлекает из архива файл для выполнения программы UPX, а затем удаляет ненужный архив.
DownloadUPX()
{
    # Определяем архитектуру для UPX
    case "$(uname -m)" in
        x86_64) arch="amd64_linux" ;;
        i386|i686) arch="i386_linux" ;;
        aarch64|arm64) arch="arm64_linux" ;;
        armv7l|arm) arch="arm_linux" ;;
        ppc64le) arch="powerpc64le_linux" ;;
        ppc) arch="powerpc_linux" ;;
        riscv64) arch="riscv64_linux" ;;
        mips) arch="mips_linux" ;;
        mipsel) arch="mipsel_linux" ;;
        armeb) arch="armeb_linux" ;;
        *) echo "Неизвестная архитектура UPX: $(uname -m), обратитесь к автору для её поддержки, или скомпилируйте исполняемый файл самостоятельно"; exit 1 ;;
    esac

LatestReleaseUPX=$(curl -s "https://api.github.com/repos/upx/upx/releases/latest" | grep -iE '"tag_name":|"version":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')
# LatestReleaseUPX="upx-5.0.2" # Из-за новой политики гитхаб приходится вручную версию указывать, если обращению с моего IP адреса к github слишком много.
binNameUPX="upx-${LatestReleaseUPX}-${arch}.tar.xz" # Тут нужно проверить последняя ли версия. Если нет, то вылетит ошибка при загрузке. А, ну и версию под архитектуру, на котором будет выполняться сжатие через upx нужно брать.
urlBinUPX="https://github.com/upx/upx/releases/latest/download/${binNameUPX}"
echo "Выполняется загрузка "$binNameUPX""
curl -L --progress-bar -# -O "$urlBinUPX"
tar -I xz -xvf "$binNameUPX" --strip-components=1 "upx-${LatestReleaseUPX}-${arch}/upx" > /dev/null && rm "$binNameUPX"
}

# Качает бинарный файл yarr с интернета для заданной архитектуры процессора
DownloadVersion()
{
echo "Происходит загрузка yarr "$LatestRelease" для архитектуры "$architecture", подождите…"
urlBin="https://github.com/nkanaev/yarr/releases/latest/download/yarr_linux_${architecture}.zip"
mkdir -p "$yarrSource/usr/bin" && curl -L --progress-bar -# -o "$yarrSource/usr/bin/yarr_linux_${architecture}.zip" "$urlBin"
unzip -qo "$yarrSource/usr/bin/yarr_linux_${architecture}.zip" yarr -d "$yarrSource/usr/bin" && rm "$yarrSource/usr/bin/yarr_linux_${architecture}.zip"
# Выдача разрешения на исполнение
chmod +x "$yarrSource/usr/bin/yarr" # Хотя файл после разархивирования и так вроде бы исполняемым является
 
	# Сжатие в случае, если был выбран нужный флаг. Если сжимать до того, как были даны права, то программа может ругаться. При использовании UPX возможны глюки работы программы, однако, раз вы тут, то выбора у вас не много по всей видимости. Скажу лишь, что я критичных глюков не ловил и всё работает. Впрочем, и непонятно насколько вообще примнение UPX замедляет скорость выполнения программы.
		if [ "$UPX_archive" = "true" ]; then
			echo "В настройках было выбрано сжатие пакетов, потому придётся подождать. Прогресс сжатия пакета в настоящее время отображён на экране ниже:"
#			upx --no-lzma --best $yarrSource/usr/bin/yarr # Это если UPX установлен в системе.
			./upx --no-lzma --best $yarrSource/usr/bin/yarr # Это если бинарный файлик разместить рядом со скриптом, не ставя в систему, тогда так удобнее будет.
			# upx --lzma вместо --no-lzma будет ещё лучше сжатие, но возможно ухудшение скорости работы программы из-за lzma (впрочем, неизвестно насколько хуже и будет ли это вообще заметно) или upx --ultra-brute будет архивировать во все возможные уровни сжатия и выберет наименьшее из них значение, но в таком случае будет очень долго этим заниматься (впрочем, итоговое значение очень редко когда будет заметно лучше, чем --best).
		fi
}

# Скачивание актуальной версии скрипта по сборке установочника
UpdateScript()
{
echo "Происходит загрузка скрипта для сборки ipk пакета ipkg-build, подождите…"
curl -Ls -O "https://github.com/openwrt/openwrt/raw/refs/heads/main/scripts/ipkg-build"
chmod +x ./ipkg-build
echo "Скрипт ipkg-build загружен"
}

# Создаёт конфигурационные файлы, даёт разрешения, выполняет сборку приложения
compileyarr()
{
	# Создаение файлов с настройками управления сервисами. Подробнее про управление сервисами в openwrt можно почитать тут: https://openwrt.org/docs/guide-user/base-system/managing_services
mkdir -p "$yarrSource"/etc/init.d/
	cat << 'EOF' > "$yarrSource"/etc/init.d/yarr	# Файл для упрвления сервисом yarr (тут описаны действия при запуске, остановке, перезапуске и так далее)
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

PROG=/usr/bin/yarr

start_service() {
    local cfg="yarr"
    local cmd_args=""

    config_load "$cfg"
    local global_cfg="global"

    # Чтение параметров из UCI (согласно полям в вашем yarr.js)
    config_get addr "$global_cfg" addr ""
    config_get db "$global_cfg" db ""
    config_get log_file "$global_cfg" log_file ""
    config_get auth_method "$global_cfg" auth_method "none"
    config_get auth_user "$global_cfg" auth_user ""
    config_get auth_pass "$global_cfg" auth_pass ""
    config_get auth_file "$global_cfg" auth_file ""
    config_get base "$global_cfg" base ""
    config_get cert_file "$global_cfg" cert_file ""
    config_get key_file "$global_cfg" key_file ""

    # Создание директорий для БД и логов (если указаны)
    if [ -n "$db" ]; then
        db_dir=$(dirname "$db")
        [ -d "$db_dir" ] || mkdir -p "$db_dir"
    fi
    if [ -n "$log_file" ]; then
        log_dir=$(dirname "$log_file")
        [ -d "$log_dir" ] || mkdir -p "$log_dir"
        touch "$log_file" 2>/dev/null
    fi

    # Сборка аргументов командной строки
    [ -n "$addr" ] && cmd_args="$cmd_args -addr $addr"
    [ -n "$db" ] && cmd_args="$cmd_args -db $db"
    [ -n "$log_file" ] && cmd_args="$cmd_args -log-file $log_file"
    [ -n "$base" ] && cmd_args="$cmd_args -base $base"
    [ -n "$cert_file" ] && cmd_args="$cmd_args -cert-file $cert_file"
    [ -n "$key_file" ] && cmd_args="$cmd_args -key-file $key_file"

    # Аутентификация: взаимоисключающие методы
    if [ "$auth_method" = "file" ] && [ -n "$auth_file" ]; then
        cmd_args="$cmd_args -auth-file $auth_file"
    elif [ "$auth_method" = "basic" ] && [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        cmd_args="$cmd_args -auth ${auth_user}:${auth_pass}"
    fi
    # При "none" – ничего не добавляем

    procd_open_instance
    procd_set_param command "$PROG" $cmd_args
    procd_set_param respawn      # автоматический перезапуск при падении
    procd_close_instance
}

stop_service() {
    killall -9 $PROG 2>/dev/null
}

reload_service() {
    procd_send_signal "$PROG" $cmd_args
}
EOF


mkdir -p "$yarrSource"/etc/config/
	cat << 'EOF' > "$yarrSource"/etc/config/yarr # Создаение файла с настройками UCI
config yarr 'global'
    option addr '192.168.1.1:7070'
    option db '/tmp/yarr/yarr.db'
EOF

mkdir -p "$yarrSource"/CONTROL/
	cat << 'EOF' > "$yarrSource"/CONTROL/postinst	# Создание файла с действиями после установки (обычный sh скрипт)
#!/bin/sh

service yarr enable
service yarr start
EOF

	cat << 'EOF' > "$yarrSource"/CONTROL/prerm	# Создание файла с действиями перед удалением (обычный sh скрипт)
#!/bin/sh

service yarr stop
service yarr disable
EOF

	cat << 'EOF' > "$yarrSource"/CONTROL/postrm	# Создание файла с действиями после удаления (обычный sh скрипт)
#!/bin/sh
	rm -rf /usr/bin/yarr
EOF

	cat << EOF > "$yarrSource"/CONTROL/control # Далее нужно внимательно проверить, верна ли информация, указанная ниже в файле control. Обязательно должны присутсвовать разделы Package, Version, Architecture, Maintainer, Description, хотя насчёт Description и Maintainer я не уверен, впрочем, может и ещё меньше можно оставить полей. Но лишняя информация вряд-ли повредит, особенно если она верно указана. Скрипт ipkg-build умеет заполнять Installed-Size автоматически. Так же можно использовать ещё в control файле ipk пункт Depends:, в котором можно указазать от каких других пакетов зависит данный пакет для своей работы. SourceDateEpoch: как я понял, это в формате Unix time время крайнего измнения исходного кода.
Package: yarr
Version: $LatestRelease
Source: feeds/packages/yarr
SourceName: yarr
License: MIT
LicenseFiles: LICENSE
Section: net
SourceDateEpoch: 1721151000
Architecture: $PackageArchitecture
URL: https://github.com/nkanaev/yarr
Maintainer: YouROK <nkanaev@live.com>
Installed-Size: 
Description: yet another rss reader
EOF

# curl -Ls -O "https://github.com/YouROK/yarr/raw/refs/heads/master/LICENSE" # Скачиваем файл лицензии, только непонятно нужно ли и если нужно, то куда его класть.

# Выдача разрешений файлам
chmod +x "$yarrSource/etc/init.d/yarr"
chmod +x "$yarrSource/CONTROL/postinst"
chmod +x "$yarrSource/CONTROL/prerm"
chmod +x "$yarrSource/CONTROL/postrm"

# Сборка пакета
echo "Происходит сборка yarr для архитектуры "$PackageArchitecture", подождите…"
./ipkg-build "$yarrSource/"
}

compileyarrLuci() # Создание файлов и комплияция пакета для оболочки LuCI
{
mkdir -p "$yarrLuciSource"/www/luci-static/resources/view/
	cat << 'EOF' > "$yarrLuciSource"/www/luci-static/resources/view/yarr.js	# Создание файла на языке JavaScript для отрисовки веб интерфейса.
'use strict';
'require form';
'require uci';

return L.view.extend({
    render: function () {
        var m, s, o;

        m = new form.Map('yarr', 'Yarr RSS Reader', 'Настройки RSS-агрегатора Yarr');

        s = m.section(form.NamedSection, 'global', 'yarr', 'Global parameters');

        o = s.option(form.Flag, 'autostart', 'Start yarr on system boot');

        o = s.option(form.DummyValue, '_links', 'Web interface');
        o.rawhtml = true;
        o.cfgvalue = function() {
            var addr = uci.get('yarr', 'global', 'addr') || '127.0.0.1:7070';
            var protocol = (uci.get('yarr', 'global', 'cert_file') ? 'https' : 'http');
            return '<a href="' + protocol + '://' + addr + '" target="_blank">Open Yarr</a>';
        };

        o = s.option(form.Value, 'addr', 'Listen address');
        o.description = 'Адрес и порт, на котором сервер будет принимать соединения. Формат: IP:PORT, например 192.168.1.1:7070 или 0.0.0.0:7070. По умолчанию 127.0.0.1:7070 — значит, сервер доступен только с локальной машины.';
        o.default = '192.168.1.1:7070';
        o.placeholder = '127.0.0.1:7070';

        o = s.option(form.Value, 'db', 'Database path');
        o.description = 'Путь к файлу базы данных (SQLite). Если не указан, yarr использует встроенную БД, пожирая внутренюю память устройства. Поэтому лучше хранить базу данных в оперативной памяти (в папке /tmp/), но из минусов такого подхода отмечу, что удаление файла yarr.db приводит к удалению и списка всех подписок (а оно выполняется каждый раз при перезагрузке роутера), за то nand память не портится и не переполняется. Для постоянного пользования лучший вариант - использовать внешнее хранилище, например, в разлеле /mnt/sda1/yarr/yarr.db, данные в котором не будут теряться при каждой перезагрузке.';
        o.default = '/tmp/yarr/yarr.db';
        o.placeholder = '~/.local/bin/yarr.db';

        o = s.option(form.Value, 'log_file', 'Log file path');
        o.description = 'Запись логов не в stdout, а в указанный файл. Это путь к файлу лога (оставьте пустым для вывода в stdout)';

        // ---------- Аутентификация: выбор метода ----------
        var authMethod = s.option(form.ListValue, 'auth_method', 'Authentication method');
        authMethod.value('none', 'None');
        authMethod.value('basic', 'Basic auth (username/password)');
        authMethod.value('file', 'Auth file (username:password in file)');
        authMethod.default = 'none';
        authMethod.description = 'Базовая HTTP-аутентификация в формате логин:пароль. Используйте, если хотите защитить доступ к веб-интерфейсу. Желательно выбрать метод "Auth file" по причине того, что при выборе Basic auth режима логин и пароль доступа к yarr будет отображаться в списке процессов.';

        // Поля для basic auth (видны, если auth_method == 'basic')
        o = s.option(form.Value, 'auth_user', 'Username');
        o.depends('auth_method', 'basic');
        o = s.option(form.Value, 'auth_pass', 'Password');
        o.password = true;
        o.depends('auth_method', 'basic');

        // Поле для файла аутентификации (видно, если auth_method == 'file')
        o = s.option(form.Value, 'auth_file', 'Auth file path');
        o.description = 'Путь к файлу, содержащему строку username:password. Права доступа 600.';
        o.depends('auth_method', 'file');
        // ------------------------------------------------

        o = s.option(form.Value, 'base', 'Base path');
        o.description = 'Базовый путь к сервису yarr, например, http://192.168.1.1:7070/yarr/). По умолчанию пусто — сервер обслуживается из корня т.е. http://192.168.1.1:7070/';

        o = s.option(form.Value, 'cert_file', 'SSL certificate file');
        o.description = 'Путь к SSL-сертификату для включения HTTPS (например, fullchain.pem).';

        o = s.option(form.Value, 'key_file', 'SSL key file');
        o.description = 'Путь к приватному ключу SSL (например, privkey.pem).';

        return m.render();
    }
});
EOF

mkdir -p "$yarrLuciSource"/usr/share/rpcd/acl.d/
	cat << 'EOF' > "$yarrLuciSource"/usr/share/rpcd/acl.d/luci-app-yarr.json	# Создание структуры доступа к разным действиям и папкам для JavaScript файла программы.
{
        "luci-app-yarr": {
                "description": "Grant access to cat yarr OpenWrt config",
                "read": {
                        "uci": [
                                "yarr"
                        ]
                },
                "write": {
                        "uci": [
                                "yarr"
                        ]
                }
        }
}
EOF

mkdir -p "$yarrLuciSource"/usr/share/luci/menu.d/
	cat << 'EOF' > "$yarrLuciSource"/usr/share/luci/menu.d/luci-app-yarr.json	# Создание структуры меню, т.е. в каком разделе LuCI искать программу.
{
        "admin/services/yarr": {
                "title": "yarr",
                "action": {
                        "type": "view",
                        "path": "yarr"
                },
                "depends": {
                        "acl": [ "luci-app-yarr" ],
                        "uci": { "yarr": true }
                }
        }
}
EOF

mkdir -p "$yarrLuciSource"/CONTROL/
	cat << EOF > "$yarrLuciSource"/CONTROL/control	# Далее нужно внимательно проверить, верна ли информация, указанная ниже в файле control. Обязательно должны присутсвовать разделы Package, Version, Architecture, Maintainer, Description, хотя насчёт Description и Maintainer я не уверен, впрочем, может и ещё меньше можно оставить полей. Но лишняя информация вряд-ли повредит, особенно если она верно указана. Скрипт ipkg-build умеет заполнять Installed-Size автоматически. Так же можно использовать ещё в control файле ipk пункт Depends:, в котором можно указазать от каких других пакетов зависит данный пакет для своей работы. SourceDateEpoch: как я понял, это в формате Unix time время крайнего измнения исходного кода.
Package: luci-app-yarr
Version: 1.0
Depends: yarr
Source: feeds/packages/luci-app-yarr
SourceName: luci-app-yarr
License: MIT
LicenseFiles: LICENSE
Section: luci
SourceDateEpoch: 1763931600
Architecture: all
URL: https://github.com/nkanaev/yarr
Maintainer: YouROK <nkanaev@live.com>
Installed-Size: 
Description: yet another rss reader
EOF
}



# Основной алгоритм действий скрипта!

UpdateScript

# Качает UPX, если флаг $UPX_archive равен true
if [ "$UPX_archive" = "true" ]; then
	DownloadUPX
fi

LatestRelease=$(curl -s "https://api.github.com/repos/nkanaev/yarr/releases/latest" | grep -iE '"tag_name":|"version":' | sed -E 's/.*"([^"]+)".*/\1/') # Получение номера последней версии yarr, чтобы её скачивать для разных архитектур.

buildInstallerPackage() # Это функция, которая каждый раз при вызове берёт новое значение архитектуры и делает для этой архитектуры сборку установочного IPK файла (дальше по коду будет видно).
{
mkdir -p "$yarrSource"
DownloadVersion
for PackageArchitecture in $PackageArchitectures; do # Так как в yarr одно значение архитектуры покрывает несколько значений архитектур в OpenWrt, то чтобы лишний раз не качать файлы сделал такое зацикливание.
compileyarr
done
rm -rf "$yarrSource" # Удаление папки c файлами для определённой архитектуры, чтобы создать новую папку уже для другой архитектуры и качать туда другой бинарный файл.
}

# Сборка с разными архитектурами
# Список архитектур openwrt доступен по адресу: https://openwrt.org/docs/techref/instructionset/start Ещё можно изучить в разделе https://downloads.openwrt.org/releases/ файлы типа packages-*
# Файлы названия архитектуры на openwrt обычно с несколько другим названием, чем выдаёт $uname -m. Посмотреть архитектуру системы, которая используется для сверки ipk пакетов, можно в файе /etc/openwrt_release. Например, командой grep ARCH /etc/openwrt_release
# За поддержкой новых архитектур обращайтесь к автору на официальной странице https://github.com/YouROK/yarr

PackageArchitectures="aarch64_armv8-a aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic" architecture="arm64"
buildInstallerPackage

PackageArchitectures="x86_64" architecture="amd64"
buildInstallerPackage

PackageArchitectures="arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a7_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3 arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4 arm_cortex-a53_neon-vfpv4" architecture="armv7" # Архитектура ARMv7, как я понял
buildInstallerPackage

#PackageArchitectures="riscv64_riscv64 riscv64_generic" architecture="riscv64"
#buildInstallerPackage
# К сожалению, нет такой архитектуры в сборке у автора. Возможно, когда-нибудь будет и будет это очень удобно.


# Сборка пакета для LuCI
compileyarrLuci # Делаем структуру папок и файлов для модуля к LuCI
echo "Происходит сборка дополнения yarr для LuCI, подождите…"
./ipkg-build "$yarrLuciSource/"
rm -rf "$yarrLuciSource" # Удаление папки, используемой для сборки LuCI дополнения за ненадобностью.

rm -rf ipkg-build # Удаление файла создаения IPK файлов. Но сам скрипт и созданные файлы для разных архитектур остаются.

if [ "$UPX_archive" = "true" ]; then
rm -rf upx # Удаление файла, котрый был использован для сжатияи пакетов
fi

#Диалог выхода из программы с предложением удалить файлы.
while true; do
	read -rp "Работа скрипта завершена. Удалить ли теперь и сам скрипт "$0"? [Д/н]: " answer
	case "$answer" in
		""|Д|д|Да|да|Y|y|Yes|yes)
			rm -rf "$0"
			exit 0
			;;
		Н|н|Нет|нет|N|n|No|no)
			exit 0
			;;
		*)
			echo "Неправильный ввод. Попробуйте еще раз."
			continue
			;;
		esac
done
