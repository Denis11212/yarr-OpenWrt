#!/bin/sh
# Скрипт сборки ipk-пакетов yarr (yet another rss reader) для OpenWrt.
# Автор yarr: https://github.com/nkanaev
# Требует: curl tar xz unzip jq coreutils grep sed findutils

YarrSource="yarrSource"
YarrLuciSource="yarrLuciSource"
YarrI18nSource="yarrI18nSource"

# ---------- Проверка зависимостей ----------
missing=""
for cmd in curl tar xz unzip jq grep sed find; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [ -n "$missing" ]; then
    echo "❌ Отсутствуют пакеты:$missing"
    echo "Установите их перед запуском (например: opkg install$missing или apt install$missing)"
    exit 1
fi

DownloadVersion() {
    echo "Загрузка yarr ${LatestRelease} для ${architecture}…"
    local url="https://github.com/nkanaev/yarr/releases/download/${LatestRelease}/yarr_linux_${architecture}.zip"
    mkdir -p "$YarrSource/usr/bin"

    if ! curl -Lfs -o "$YarrSource/usr/bin/yarr.zip" "$url"; then
        echo "❌ Ошибка загрузки $url"
        return 1
    fi

    if ! unzip -t "$YarrSource/usr/bin/yarr.zip" >/dev/null 2>&1; then
        echo "❌ Скачанный файл повреждён или не является ZIP-архивом."
        rm -f "$YarrSource/usr/bin/yarr.zip"
        return 1
    fi

    unzip -qo "$YarrSource/usr/bin/yarr.zip" yarr -d "$YarrSource/usr/bin"
    rm -f "$YarrSource/usr/bin/yarr.zip"

    if [ ! -f "$YarrSource/usr/bin/yarr" ]; then
        echo "❌ Ошибка: бинарник yarr не найден в архиве."
        return 1
    fi

    chmod +x "$YarrSource/usr/bin/yarr"
}

compileYarr() {
    mkdir -p "$YarrSource"/etc/init.d "$YarrSource"/etc/config "$YarrSource"/CONTROL \
             "$YarrSource"/usr/share/rpcd/acl.d "$YarrSource"/usr/libexec/rpcd

    cat << 'EOF' > "$YarrSource"/etc/init.d/yarr
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG=/usr/bin/yarr
YARR_USER="yarr"
YARR_GROUP="yarr"

_prepare_dir() {
    local p="$1"
    [ -L "$p" ] && { logger -t yarr "Symlink $p — отказ"; return 1; }
    [ ! -d "$p" ] && { mkdir -p "$p" && chown "$YARR_USER:$YARR_GROUP" "$p" && chmod 750 "$p"; }
    return 0
}

start_service() {
    local cfg="yarr" addr db log_file auth_method auth_user auth_pass auth_file base cert key
    config_load "$cfg"
    config_get addr global addr "0.0.0.0:7070"
    config_get db global db "/tmp/yarr/yarr.db"
    config_get log_file global log_file ""
    config_get auth_method global auth_method "none"
    config_get auth_user global auth_user ""
    config_get auth_pass global auth_pass ""
    config_get auth_file global auth_file ""
    config_get base global base ""
    config_get cert global cert_file ""
    config_get key global key_file ""

    [ ! -x "$PROG" ] && { logger -t yarr "Бинарник не найден"; return 1; }
    id "$YARR_USER" >/dev/null 2>&1 || { logger -t yarr "Пользователь $YARR_USER не найден"; return 1; }

    [ -n "$db" ] && _prepare_dir "$(dirname "$db")"
    [ -n "$log_file" ] && _prepare_dir "$(dirname "$log_file")"

    procd_open_instance
    procd_set_param command "$PROG"
    [ -n "$addr" ] && procd_append_param command -addr "$addr"
    [ -n "$db" ] && procd_append_param command -db "$db"
    [ -n "$log_file" ] && procd_append_param command -log-file "$log_file"
    [ -n "$base" ] && procd_append_param command -base "$base"
    [ -n "$cert" ] && procd_append_param command -cert-file "$cert"
    [ -n "$key" ] && procd_append_param command -key-file "$key"
    case "$auth_method" in
        file) [ -n "$auth_file" ] && procd_append_param command -auth-file "$auth_file" ;;
        basic) [ -n "$auth_user" ] && [ -n "$auth_pass" ] && procd_append_param command -auth "${auth_user}:${auth_pass}" ;;
    esac
    procd_set_param user "$YARR_USER"
    procd_set_param group "$YARR_GROUP"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "yarr"
}
EOF

    cat << 'EOF' > "$YarrSource"/etc/config/yarr
config yarr 'global'
    option addr '0.0.0.0:7070'
    option db '/tmp/yarr/yarr.db'
    option auth_method 'none'
EOF

    cat << 'EOF' > "$YarrSource"/CONTROL/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
. /lib/functions.sh
U="yarr"; G="yarr"; DB_DEF="/tmp/yarr/yarr.db"
group_exists "$G" || group_add_next "$G" >/dev/null
GID="$(grep -s "^${G}:" /etc/group | cut -d: -f3)"
config_load yarr 2>/dev/null
config_get DB global db "$DB_DEF"
[ -z "$DB" ] && DB="$DB_DEF"
user_exists "$U" || user_add "$U" "" "$GID" "Yarr daemon" "$(dirname "$DB")" "/bin/false"
[ ! -d "$(dirname "$DB")" ] && mkdir -p "$(dirname "$DB")" && chown "$U:$G" "$(dirname "$DB")" && chmod 750 "$(dirname "$DB")"
[ -f "$DB" ] && chown "$U:$G" "$DB" 2>/dev/null
/etc/init.d/yarr enable >/dev/null 2>&1
/etc/init.d/yarr start >/dev/null 2>&1
exit 0
EOF

    cat << 'EOF' > "$YarrSource"/CONTROL/prerm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/yarr stop >/dev/null 2>&1
/etc/init.d/yarr disable >/dev/null 2>&1
exit 0
EOF

    cat << EOF > "$YarrSource"/CONTROL/control
Package: yarr
Version: $LatestRelease
Depends: libc, libsqlite3, ca-bundle
Source: feeds/packages/yarr
SourceName: yarr
License: MIT
Section: net
Architecture: $PackageArchitecture
URL: https://github.com/nkanaev/yarr
Maintainer: nkanaev
Description: yet another rss reader — lightweight web-based RSS aggregator with SQLite storage, OPML import/export, dark theme, full-text search.
EOF

    cat << 'EOF' > "$YarrSource"/usr/share/rpcd/acl.d/yarr.json
{
    "yarr": {
        "description": "Yarr rpcd access",
        "read":  { "uci": ["yarr"], "ubus": { "yarr": ["status","load","log_read","version_bin","db_info","list_mounts"] } },
        "write": { "uci": ["yarr"], "ubus": { "yarr": ["service","opml_export","opml_import"] } }
    }
}
EOF

    cat << 'RPCEOF' > "$YarrSource"/usr/libexec/rpcd/yarr
#!/bin/sh
. /usr/share/libubox/jshn.sh
YARR_USER="yarr"; YARR_BIN="/usr/bin/yarr"

json_error() { json_init; json_add_boolean ok 0; json_add_string error "$1"; json_dump; exit 0; }
cfg_get() { uci -q get "yarr.global.$1" 2>/dev/null; }

get_pid() {
    local p t
    if command -v pgrep >/dev/null; then pgrep -x "$YARR_BIN" 2>/dev/null | head -n1; return; fi
    for p in /proc/[0-9]*/exe; do
        [ -e "$p" ] || continue
        t="$(readlink "$p" 2>/dev/null)"
        [ "$t" = "$YARR_BIN" ] && { p="${p#/proc/}"; echo "${p%%/*}"; return; }
    done
}

get_process_info() {
    local pid uid user cmdline rss rest ticks upt hz cores mem_total mem_avail proc_uptime cpu_pct starttime
    pid=$(get_pid); [ -z "$pid" ] && return
    [ -r "/proc/$pid/stat" ] || return
    uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    user=$(awk -F: -v u="$uid" '$3==u{print $1;exit}' /etc/passwd 2>/dev/null)
    cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
    ticks=$(printf '%s' "$rest" | awk '{print $12+$13}')
    starttime=$(printf '%s' "$rest" | awk '{print $20}')
    upt=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    proc_uptime=$((upt - starttime / hz))
    cpu_pct=0
    [ "$proc_uptime" -gt 0 ] && [ "$cores" -gt 0 ] && cpu_pct=$((ticks * 100 / (proc_uptime * hz * cores)))
    [ "$cpu_pct" -gt 100 ] && cpu_pct=100
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" \
        "$pid" "${user:-$uid}" "${rss:-0}" "$cores" "$mem_total" "$mem_avail" "$proc_uptime" "$cpu_pct" "$hz" "$cmdline"
}

method_status() {
    local running=0 enabled=0 pid
    /etc/init.d/yarr status >/dev/null 2>&1 && running=1
    /etc/init.d/yarr enabled >/dev/null 2>&1 && enabled=1
    pid=$(get_pid)
    json_init
    json_add_boolean ok 1
    json_add_boolean running "$running"
    json_add_boolean enabled "$enabled"
    [ -n "$pid" ] && json_add_int pid "$pid"
    json_add_string addr "$(cfg_get addr)"
    json_add_string db "$(cfg_get db)"
    json_dump
}

method_load() {
    local running=0 enabled=0 raw pid
    /etc/init.d/yarr status >/dev/null 2>&1 && running=1
    /etc/init.d/yarr enabled >/dev/null 2>&1 && enabled=1
    raw="$(get_process_info)"; pid=$(get_pid)
    json_init
    json_add_boolean ok 1
    json_add_object service
        json_add_boolean running "$running"
        json_add_boolean enabled "$enabled"
        [ -n "$pid" ] && json_add_int pid "$pid"
        json_add_string addr "$(cfg_get addr)"
        json_add_string db "$(cfg_get db)"
        json_add_string cert "$(cfg_get cert_file)"
        json_add_string auth_method "$(cfg_get auth_method)"
    json_close_object
    json_add_object proc
    if [ -n "$raw" ]; then
        json_add_boolean available 1
        local OLD_IFS="$IFS"; IFS="|"; set -- $raw; IFS="$OLD_IFS"
        json_add_int pid "${1:-0}"
        json_add_string user "${2:-unknown}"
        json_add_int rss_kb "${3:-0}"
        json_add_int cores "${4:-1}"
        json_add_int mem_total_kb "${5:-0}"
        json_add_int mem_avail_kb "${6:-0}"
        json_add_int uptime_sec "${7:-0}"
        json_add_int cpu_pct "${8:-0}"
        json_add_string cmdline "${10:-}"
    else
        json_add_boolean available 0
    fi
    json_close_object
    json_dump
}

method_service() {
    local action="$1" rc=1
    case "$action" in
        start|stop|restart|enable|disable) "/etc/init.d/yarr" "$action" >/dev/null 2>&1; rc=$? ;;
        *) json_error "unsupported action" ;;
    esac
    json_init
    json_add_boolean ok "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
    json_add_int rc "$rc"
    json_dump
}

method_version_bin() {
    json_init
    json_add_boolean ok 1
    json_add_string stdout "$("$YARR_BIN" -version 2>/dev/null || echo "unknown")"
    json_dump
}

method_db_info() {
    local db size
    db="$(cfg_get db)"
    size=-1
    [ -f "$db" ] && size=$(wc -c < "$db" | tr -d ' ')
    json_init
    json_add_boolean ok 1
    json_add_string path "$db"
    json_add_int size "$size"
    [ -f "$db" ] && json_add_boolean exists 1 || json_add_boolean exists 0
    json_dump
}

method_log_read() {
    local name="$1" offset="$2" limit="$3" f size chunk
    is_num() { case "$1" in ''|*[!0-9]*) return 1;; esac; }
    is_num "$offset" || offset=0
    is_num "$limit" || limit=65536
    if [ "$name" = "syslog" ]; then
        chunk="$(logread -e "yarr" 2>/dev/null | tail -c 32768)"
    else
        f="$(cfg_get log_file)"
        [ -f "$f" ] || { json_init; json_add_boolean ok 1; json_add_boolean exists 0; json_add_string content ""; json_dump; return; }
        size=$(wc -c < "$f" | tr -d ' ')
        [ "$offset" -gt "$size" ] && offset=0
        chunk="$(tail -c +$((offset + 1)) "$f" 2>/dev/null | head -c "$limit")"
    fi
    json_init
    json_add_boolean ok 1
    json_add_boolean exists 1
    json_add_string content "$chunk"
    json_dump
}

method_list_mounts() {
    local tmp_file="/tmp/.yarr_mounts_$$"
    json_init
    json_add_boolean ok 1
    json_add_array mounts
    df -P 2>/dev/null | awk 'NR>1 && $6 ~ /^\/(mnt|media|overlay|tmp|home|opt|srv)/ {print $6"\t"$2"\t"$4"\t"$5}' > "$tmp_file"
    while IFS="$(printf '\t')" read -r mpath msize mavail muse; do
        [ -n "$mpath" ] || continue
        json_add_object ""
        json_add_string path "$mpath"
        json_add_string size "$msize"
        json_add_string avail "$mavail"
        json_add_string used "$muse"
        json_close_object
    done < "$tmp_file"
    rm -f "$tmp_file"
    json_close_array
    json_dump
}

method_opml_export() {
    local db target rc
    db="$(cfg_get db)"
    target="/tmp/yarr_feeds_$(date +%Y%m%d_%H%M%S).opml"
    [ -f "$db" ] || json_error "no database"
    command -v sqlite3 >/dev/null || json_error "sqlite3 not installed"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<opml version="1.0"><head><title>yarr feeds</title></head><body>'
        sqlite3 "$db" "SELECT title, link FROM feeds;" 2>/dev/null | while IFS='|' read -r title link; do
            t=$(printf '%s' "$title" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
            printf '  <outline text="%s" xmlUrl="%s"/>\n' "$t" "$link"
        done
        echo '</body></opml>'
    } > "$target"
    rc=$?
    json_init
    json_add_boolean ok "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
    json_add_string path "$target"
    json_add_int size "$(wc -c < "$target" | tr -d ' ')"
    json_dump
}

method_opml_import() {
    local file="$1" db
    db="$(cfg_get db)"
    [ -f "$file" ] || json_error "file not found"
    [ -f "$db" ] || json_error "database missing"
    command -v sqlite3 >/dev/null || json_error "sqlite3 not installed"
    grep -oE 'xmlUrl="[^"]+"' "$file" | sed 's/xmlUrl="//;s/"$//' | while read -r url; do
        sqlite3 "$db" "INSERT OR IGNORE INTO feeds(link,title) VALUES('$url','$(printf '%s' "$url" | sed "s/'/''/g")');" 2>/dev/null
    done
    /etc/init.d/yarr restart >/dev/null 2>&1
    json_init
    json_add_boolean ok 1
    json_dump
}

case "$1" in
    list)
        cat <<'LISTEOF'
{
    "status": {},
    "load": {},
    "service": {"action":"string"},
    "version_bin": {},
    "db_info": {},
    "log_read": {"name":"string","offset":"number","limit":"number"},
    "list_mounts": {},
    "opml_export": {},
    "opml_import": {"file":"string"}
}
LISTEOF
        ;;
    call)
        method="$2"
        ACTION=""; FILE=""
        json_input="$(cat)"
        [ -n "$json_input" ] && { json_load "$json_input" 2>/dev/null; json_get_var ACTION action; json_get_var FILE file; }
        case "$method" in
            status) method_status ;;
            load) method_load ;;
            service) method_service "$ACTION" ;;
            version_bin) method_version_bin ;;
            db_info) method_db_info ;;
            log_read) method_log_read "$ACTION" 0 65536 ;;
            list_mounts) method_list_mounts ;;
            opml_export) method_opml_export ;;
            opml_import) method_opml_import "$FILE" ;;
            *) json_error "unknown method" ;;
        esac
        ;;
    *) exit 1 ;;
esac
RPCEOF

    chmod +x "$YarrSource"/etc/init.d/yarr "$YarrSource"/CONTROL/postinst "$YarrSource"/CONTROL/prerm "$YarrSource"/usr/libexec/rpcd/yarr

    echo "Сборка yarr для ${PackageArchitecture}…"
    LC_ALL=C ./ipkg-build "$YarrSource/"
}

compileYarrLuci() {
    mkdir -p "$YarrLuciSource"/www/luci-static/resources/view \
             "$YarrLuciSource"/usr/share/rpcd/acl.d \
             "$YarrLuciSource"/usr/share/luci/menu.d \
             "$YarrLuciSource"/CONTROL

    cat << 'JSEOF' > "$YarrLuciSource"/www/luci-static/resources/view/yarr.js
'use strict';
'require view'; 'require form'; 'require ui'; 'require uci'; 'require poll'; 'require rpc';

var callYarrLoad     = rpc.declare({ object: 'yarr', method: 'load',        expect: {} });
var callYarrStatus   = rpc.declare({ object: 'yarr', method: 'status',      expect: {} });
var callYarrService  = rpc.declare({ object: 'yarr', method: 'service',     params: ['action'], expect: {} });
var callYarrVersion  = rpc.declare({ object: 'yarr', method: 'version_bin', expect: {} });
var callYarrDbInfo   = rpc.declare({ object: 'yarr', method: 'db_info',     expect: {} });
var callYarrLogRead  = rpc.declare({ object: 'yarr', method: 'log_read',    params: ['name','offset','limit'], expect: {} });
var callYarrOpmlExp  = rpc.declare({ object: 'yarr', method: 'opml_export', expect: {} });
var callYarrListMounts = rpc.declare({ object: 'yarr', method: 'list_mounts', expect: {} });

function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function fmtMem(kb){ if(!kb||isNaN(kb))return _('N/A'); if(kb>=1024)return Math.round(kb/1024)+' '+_('MB'); return Math.round(kb)+' '+_('KB'); }
function fmtSize(b){ if(!b||b<0)return _('N/A'); if(b>=1048576)return (b/1048576).toFixed(2)+' '+_('MB'); if(b>=1024)return (b/1024).toFixed(2)+' '+_('KB'); return b+' '+_('B'); }
function fmtUptime(s){ if(!s||s<0)return _('N/A'); var d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60),sec=s%60; var p=[]; if(d)p.push(d+'d'); if(h||d)p.push(h+'h'); if(m||h||d)p.push(m+'m'); p.push(sec+'s'); return p.join(' '); }

function openStorageSelector() {
    var container = E('div');
    container.appendChild(E('p', {}, _('Select a mounted drive for Yarr storage.')));
    var loadingDiv = E('div', { style: 'text-align:center; padding:10px;' }, _('Loading available mounts…'));
    container.appendChild(loadingDiv);
    var mountsContainer = E('div');
    container.appendChild(mountsContainer);
    container.appendChild(E('div', { 'class': 'right' }, [
        E('button', { 'class': 'btn', click: ui.hideModal }, _('Close'))
    ]));
    ui.showModal(_('Select Storage Location'), [container]);
    callYarrListMounts().then(function(res) {
        if (loadingDiv.parentNode) loadingDiv.parentNode.removeChild(loadingDiv);
        if (!res || !res.ok || !res.mounts || res.mounts.length === 0) {
            mountsContainer.appendChild(E('div', { 'class': 'alert-message warning' }, _('No mounted drives found.')));
            return;
        }
        var table = E('table', { 'class': 'table' }, [
            E('tr', { 'class': 'tr table-titles' }, [
                E('th', { 'class': 'th', style: 'text-align:left;' }, _('Path')),
                E('th', { 'class': 'th', style: 'text-align:right;' }, _('Size')),
                E('th', { 'class': 'th', style: 'text-align:right;' }, _('Available')),
                E('th', { 'class': 'th', style: 'text-align:right;' }, _('Used')),
                E('th', { 'class': 'th', style: 'text-align:center;' }, _('Action'))
            ])
        ]);
        res.mounts.forEach(function(m) {
            var basePath = m.path.replace(/\/+$/, '');
            var fullPath = basePath + '/yarr';
            table.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', style: 'font-family:monospace; font-size:.85em;' }, [
                    E('div', { style: 'font-weight:bold;' }, esc(basePath)),
                    E('div', { style: 'color:#888; font-size:.8em; margin-top:2px;' }, '→ ' + esc(fullPath))
                ]),
                E('td', { 'class': 'td', style: 'text-align:right;' }, esc(m.size)),
                E('td', { 'class': 'td', style: 'text-align:right; font-weight:bold; color:#28a745;' }, esc(m.avail)),
                E('td', { 'class': 'td', style: 'text-align:right;' }, esc(m.used)),
                E('td', { 'class': 'td', style: 'text-align:center;' }, [
                    E('button', {
                        'class': 'cbi-button cbi-button-action',
                        style: 'padding:2px 6px; font-size:.8em;',
                        click: function() { selectStoragePath(fullPath); }
                    }, _('Select'))
                ])
            ]));
        });
        mountsContainer.appendChild(table);
    }).catch(function(err) {
        if (loadingDiv.parentNode) loadingDiv.parentNode.removeChild(loadingDiv);
        mountsContainer.appendChild(E('div', { 'class': 'alert-message error' }, _('Failed to load mounts:') + ' ' + esc(err.message)));
    });
}

function selectStoragePath(path) {
    var pathInput = document.getElementById('widget.cbid.yarr.global.db');
    if (!pathInput) {
        var wrapper = document.getElementById('cbid.yarr.global.db');
        if (wrapper) pathInput = wrapper.querySelector('input');
    }
    if (pathInput) {
        pathInput.value = path + '/yarr.db';
        pathInput.dispatchEvent(new Event('input', { bubbles: true }));
        pathInput.dispatchEvent(new Event('change', { bubbles: true }));
        pathInput.style.transition = 'background-color 0.3s';
        pathInput.style.backgroundColor = '#d4edda';
        setTimeout(function() { pathInput.style.backgroundColor = ''; }, 2500);
    }
    ui.hideModal();
    ui.addNotification(null, E('p', _('Storage path set to:') + ' ' + esc(path + '/yarr.db') + '. ' + _('Click "Save & Apply" to confirm.')));
}

function openLiveTail(logname, title){
    var offset=0, init=false, liveInt=null, isLive=false;
    var logPre=E('pre',{style:'max-height:500px;overflow:auto;background:#1e1e1e;color:#d4d4d4;padding:15px;font-family:monospace;white-space:pre;font-size:.85em;border:1px solid #444;'});
    var toggleBtn=E('button',{'class':'cbi-button cbi-button-action'},_('Start Live Tail'));
    function load(){
        return callYarrLogRead(logname,offset,65536).then(function(r){
            if(!r||!r.ok||!r.exists){ if(!init)logPre.textContent=_('Log empty.'); return; }
            var stick=!init||logPre.scrollHeight-logPre.scrollTop-logPre.clientHeight<40;
            if(!init){logPre.textContent=r.content;init=true;} else if(r.content){
                var sp=document.createElement('span'); sp.style.color='#4ec9b0'; sp.textContent=r.content;
                logPre.appendChild(sp); setTimeout(function(){sp.style.color='#d4d4d4';},2000);
            }
            offset=(r.content||'').length+offset;
            if(stick)logPre.scrollTop=logPre.scrollHeight;
        });
    }
    toggleBtn.onclick=function(){
        if(isLive){ isLive=false; toggleBtn.textContent=_('Start Live Tail'); toggleBtn.classList.remove('cbi-button-reset'); toggleBtn.classList.add('cbi-button-action'); clearInterval(liveInt); }
        else{ isLive=true; toggleBtn.textContent=_('Stop Live Tail'); toggleBtn.classList.remove('cbi-button-action'); toggleBtn.classList.add('cbi-button-reset'); liveInt=setInterval(load,1500); }
    };
    ui.showModal(title,[
        E('div',{style:'margin-bottom:10px;'},[toggleBtn,E('button',{'class':'btn',click:ui.hideModal},_('Close'))]),
        logPre
    ]);
    load();
}

function waitForState(expect,maxWait){
    maxWait=maxWait||10000;
    return new Promise(function(res){
        var t0=Date.now();
        function ck(){ callYarrStatus().then(function(r){
            var run=!!(r&&r.ok&&r.running);
            if(run===expect||Date.now()-t0>maxWait)res(run);
            else setTimeout(ck,600);
        }).catch(function(){ setTimeout(ck,600); }); }
        ck();
    });
}

function updateAutostartButtons(isAutostart) {
    var btnEnable  = document.getElementById('cbid.yarr.global._btn_autostart_enable');
    var btnDisable = document.getElementById('cbid.yarr.global._btn_autostart_disable');
    if (btnEnable) {
        var rowEnable = btnEnable.closest('.cbi-value');
        if (rowEnable) rowEnable.style.display = isAutostart ? 'none' : '';
    }
    if (btnDisable) {
        var rowDisable = btnDisable.closest('.cbi-value');
        if (rowDisable) rowDisable.style.display = isAutostart ? '' : 'none';
    }
}

return view.extend({
    load:function(){
        return Promise.all([
            uci.load('yarr'),
            callYarrLoad().catch(function(){return{ok:false};}),
            callYarrDbInfo().catch(function(){return{ok:false};})
        ]);
    },
    render:function(data){
        var m,s,o;
        var loadRes=data[1]||{};
        var dbRes=data[2]||{};
        var svc=loadRes.service||{};
        var proc=loadRes.proc||{};
        var isRunning=!!svc.running;
        var isAutostart=!!svc.enabled;
        var addr=svc.addr||'0.0.0.0:7070';
        var protocol=svc.cert?'https':'http';
        var webUrl=protocol+'://'+window.location.hostname+':'+(addr.split(':')[1]||'7070')+(svc.base||'');

        function cardRow(l,v){return E('div',{style:'font-size:.9em;color:#555;margin-top:3px;'},[E('strong',{},l),' ',v]);}

        var stColor=isRunning?'#28a745':'#dc3545';
        var stBg=isRunning?'#e8f5e9':'#ffebee';
        var stText=isRunning?'▶ '+_('Running'):'⏸ '+_('Stopped');

        var card=E('div',{style:'background:'+stBg+';border-left:4px solid '+stColor+';padding:12px 15px;border-radius:4px;'},[
            E('div',{style:'font-size:1.2em;font-weight:bold;color:'+stColor+';'},stText),
            cardRow(_('Version:'),E('span',{id:'yarr-version'},proc.available?'…':_('N/A'))),
            cardRow(_('Web UI:'),E('a',{href:webUrl,target:'_blank'},esc(webUrl))),
            cardRow(_('Listen addr:'),E('code',{},esc(addr))),
            cardRow(_('Auth method:'),E('span',{},esc(svc.auth_method||'none'))),
            E('div',{style:'margin-top:6px;padding-top:6px;border-top:1px solid #e9ecef;font-weight:bold;'},_('Process')),
            cardRow(_('PID:'),E('span',{id:'yarr-pid'},proc.available?proc.pid:_('N/A'))),
            cardRow(_('User:'),E('span',{id:'yarr-user'},proc.available?proc.user:_('N/A'))),
            cardRow(_('Uptime:'),E('span',{id:'yarr-uptime'},proc.available?fmtUptime(proc.uptime_sec):_('N/A'))),
            cardRow(_('RAM (RSS):'),E('span',{id:'yarr-rss'},proc.available?fmtMem(proc.rss_kb):_('N/A'))),
            cardRow(_('CPU:'),E('span',{id:'yarr-cpu'},proc.available?proc.cpu_pct+'%':_('N/A'))),
            cardRow(_('Command:'),E('code',{id:'yarr-cmd',style:'font-size:.8em;word-break:break-all;'},proc.available?esc(proc.cmdline||''):'—')),
            E('div',{style:'margin-top:6px;padding-top:6px;border-top:1px solid #e9ecef;font-weight:bold;'},_('Database')),
            cardRow(_('Path:'),E('code',{},esc(svc.db||''))),
            cardRow(_('Size:'),E('span',{id:'yarr-db-size'},dbRes.ok&&dbRes.exists?fmtSize(dbRes.size):_('N/A')))
        ]);

        m=new form.Map('yarr','Yarr RSS Reader',_('Lightweight web-based RSS aggregator with SQLite, OPML import/export, dark theme, full-text search.'));

        s=m.section(form.NamedSection,'global','yarr',_('Service Status'));
        o=s.option(form.DummyValue,'_card',_('Yarr Service'));
        o.renderWidget=function(){return E('div',{'class':'cbi-value-field'},card);};

        o=s.option(form.Button,'_btn_start');
        o.title = _('Starting the service');
        o.inputtitle=_('Start'); o.inputstyle='action';
        o.onclick=function(){return callYarrService('start').then(function(){return waitForState(true);}).then(updateLive);};
        o=s.option(form.Button,'_btn_restart');
        o.title = _('Restarting the service');
        o.inputtitle=_('Restart'); o.inputstyle='action';
        o.onclick=function(){return callYarrService('restart').then(function(){return waitForState(true);}).then(updateLive);};
        o=s.option(form.Button,'_btn_stop');
        o.title = _('Stopping the service');
        o.inputtitle=_('Stop'); o.inputstyle='negative';
        o.onclick=function(){return callYarrService('stop').then(function(){return waitForState(false);}).then(updateLive);};

        o=s.option(form.Button,'_btn_autostart_enable');
        o.title = _('Autostart of the service');
        o.inputtitle=_('Disabled'); o.inputstyle='negative';
        o.onclick=function(){
            return callYarrService('enable').then(function(){
                ui.addNotification(null, E('p', _('Autostart enabled.')));
                updateAutostartButtons(true);
            }).catch(function(err){
                ui.addNotification(null, E('p', _('Failed to enable autostart:') + ' ' + esc(err.message || err)));
            });
        };
        o=s.option(form.Button,'_btn_autostart_disable');
        o.title = _('Autostart of the service');
        o.inputtitle=_('Enabled'); o.inputstyle='positive';
        o.onclick=function(){
            return callYarrService('disable').then(function(){
                ui.addNotification(null, E('p', _('Autostart disabled.')));
                updateAutostartButtons(false);
            }).catch(function(err){
                ui.addNotification(null, E('p', _('Failed to disable autostart:') + ' ' + esc(err.message || err)));
            });
        };

        o=s.option(form.Button,'_btn_syslog');
        o.title = _('System Log');
        o.inputtitle=_('System log (logread)'); o.inputstyle='neutral';
        o.onclick=function(){openLiveTail('syslog','Yarr system log');};
        o=s.option(form.Button,'_btn_logfile');
        o.title = _('Application Log');
        o.inputtitle=_('Application log'); o.inputstyle='neutral';
        o.depends('log_file_enabled','1');
        o.onclick=function(){openLiveTail('file','Yarr application log');};
        o=s.option(form.Button,'_btn_opml');
        o.title = _('Export OPML');
        o.inputtitle=_('Export OPML'); o.inputstyle='neutral';
        o.onclick=function(){
            callYarrOpmlExp().then(function(r){
                if(r&&r.ok){
                    ui.addNotification(null,E('p',_('OPML exported to:')+' '+esc(r.path)+' ('+fmtSize(r.size)+')'));
                    ui.showModal(_('OPML Export'),[
                        E('p',{},[_('Download the file via SSH:'),' ',E('code',{},'scp root@router:'+esc(r.path)+' ./')]),
                        E('div',{'class':'right'},[E('button',{'class':'btn',click:ui.hideModal},_('Close'))])
                    ]);
                }
            });
        };

        s=m.section(form.NamedSection,'global','yarr',_('Configuration'));
        o=s.option(form.Value,'addr',_('Listen address'));
        o.description=_('IP:PORT (e.g. 0.0.0.0:7070 for all interfaces or 192.168.1.1:7070 for specific IP). Warning: 0.0.0.0 makes yarr accessible from all network interfaces. Enable authentication if exposed to untrusted networks.');
        o.default='0.0.0.0:7070';

        s=m.section(form.NamedSection,'global','yarr',_('Storage & Database'));
        o=s.option(form.ListValue,'_storage_type',_('Storage location for database'));
        o.value('ram',_('RAM (/tmp/yarr)'));
        o.value('flash',_('ROM (/etc/yarr)'));
        o.value('custom',_('Custom path'));
        o.default='ram';
        o.cfgvalue=function(section_id){
            var p=uci.get('yarr',section_id,'db');
            if(!p||p.indexOf('/tmp/yarr')===0)return 'ram';
            if(p.indexOf('/etc/yarr')===0)return 'flash';
            return 'custom';
        };
        o.write=function(section_id,value){
            if(value==='ram')uci.set('yarr',section_id,'db','/tmp/yarr/yarr.db');
            else if(value==='flash')uci.set('yarr',section_id,'db','/etc/yarr/yarr.db');
        };
        o.remove = function(section_id) {};

        var infoRam=s.option(form.DummyValue,'_info_ram','');
        infoRam.depends('_storage_type','ram');
        infoRam.rawhtml=true;
        infoRam.cfgvalue=function(){
            return '<div class="alert-message info"><h4>'+_('RAM (Temporary Storage)')+'</h4><p>'+_('Data is stored in RAM (/tmp/yarr).')+'</p><p><strong>'+_('Pros:')+'</strong> '+_('High speed, no wear on router flash memory.')+'</p><p><strong>'+_('Cons:')+'</strong> '+_('All data will be lost on reboot.')+'</p></div>';
        };

        var infoFlash=s.option(form.DummyValue,'_info_flash','');
        infoFlash.depends('_storage_type','flash');
        infoFlash.rawhtml=true;
        infoFlash.cfgvalue=function(){
            return '<div class="alert-message warning"><h4>'+_('ROM (Persistent Storage)')+'</h4><p>'+_('Data is stored in router internal memory (/etc/yarr).')+'</p><p><strong>'+_('Pros:')+'</strong> '+_('Data persists across reboots.')+'</p><p><strong>'+_('Cons:')+'</strong> '+_('Frequent writes may wear out flash memory.')+'</p></div>';
        };

        var infoCustom=s.option(form.DummyValue,'_info_custom','');
        infoCustom.depends('_storage_type','custom');
        infoCustom.rawhtml=true;
        infoCustom.cfgvalue=function(){
            return '<div class="alert-message success"><h4>'+_('Custom Path')+'</h4><p>'+_('Stored in any permitted folder.')+'</p><p><strong>'+_('Pros:')+'</strong> '+_('You can use external storage.')+'</p><p><strong>'+_('Cons:')+'</strong> '+_('Requires careful path selection.')+'</p></div>';
        };

        o=s.option(form.Value,'db',_('Custom database path'));
        o.depends('_storage_type','custom');
        o.description=_('Absolute path to the database file.');
        o.rmempty=false;
        o.remove = function(section_id) {};

        o=s.option(form.Button,'_browse_drives');
        o.depends('_storage_type','custom');
        o.inputtitle=_('Browse Available Drives');
        o.inputstyle='action';
        o.onclick=function(){openStorageSelector();return Promise.resolve();};

        o=s.option(form.Flag,'log_file_enabled',_('Write log to file'));
        o.default='0';
        o=s.option(form.Value,'log_file',_('Log file path'));
        o.depends('log_file_enabled','1');
        o=s.option(form.ListValue,'auth_method',_('Authentication'));
        o.value('none',_('None')); o.value('basic',_('Basic (user/pass)')); o.value('file',_('Auth file'));
        o.default='none';
        o=s.option(form.Value,'auth_user',_('Username')); o.depends('auth_method','basic');
        o=s.option(form.Value,'auth_pass',_('Password')); o.password=true; o.depends('auth_method','basic');
        o=s.option(form.Value,'auth_file',_('Auth file path')); o.depends('auth_method','file');
        o.description=_('File with username:password, mode 600.');
        o=s.option(form.Value,'base',_('Base path')); o.description=_('E.g. /yarr/. Empty = root.');
        o=s.option(form.Value,'cert_file',_('SSL certificate')); o.description=_('PEM fullchain for HTTPS.');
        o=s.option(form.Value,'key_file',_('SSL key')); o.description=_('PEM private key.');

        function updateLive(){
            callYarrLoad().then(function(r){
                if(!r||!r.ok)return;
                var p=r.proc||{}; var sv=r.service||{};
                var run=!!sv.running;
                card.style.background=run?'#e8f5e9':'#ffebee';
                card.style.borderLeftColor=run?'#28a745':'#dc3545';
                card.firstChild.style.color=run?'#28a745':'#dc3545';
                card.firstChild.textContent=run?'▶ '+_('Running'):'⏸ '+_('Stopped');
                var el;
                el=document.getElementById('yarr-pid'); if(el)el.textContent=p.available?p.pid:_('N/A');
                el=document.getElementById('yarr-user'); if(el)el.textContent=p.available?p.user:_('N/A');
                el=document.getElementById('yarr-uptime'); if(el)el.textContent=p.available?fmtUptime(p.uptime_sec):_('N/A');
                el=document.getElementById('yarr-rss'); if(el)el.textContent=p.available?fmtMem(p.rss_kb):_('N/A');
                el=document.getElementById('yarr-cpu'); if(el)el.textContent=p.available?p.cpu_pct+'%':_('N/A');
                el=document.getElementById('yarr-cmd'); if(el)el.textContent=p.available?esc(p.cmdline||''):'—';
                callYarrVersion().then(function(v){
                    var el=document.getElementById('yarr-version');
                    if(el)el.textContent=v&&v.ok&&v.stdout?esc(v.stdout.trim()):_('N/A');
                });
                callYarrDbInfo().then(function(d){
                    var el=document.getElementById('yarr-db-size');
                    if(el)el.textContent=d&&d.ok&&d.exists?fmtSize(d.size):_('N/A');
                });
                // Обновляем видимость кнопок Start/Restart/Stop
                var btnStart   = document.getElementById('cbid.yarr.global._btn_start');
                var btnRestart = document.getElementById('cbid.yarr.global._btn_restart');
                var btnStop    = document.getElementById('cbid.yarr.global._btn_stop');
                if (btnStart)   { var r = btnStart.closest('.cbi-value');   if (r) r.style.display = run ? 'none' : ''; }
                if (btnRestart) { var r = btnRestart.closest('.cbi-value'); if (r) r.style.display = run ? '' : 'none'; }
                if (btnStop)    { var r = btnStop.closest('.cbi-value');    if (r) r.style.display = run ? '' : 'none'; }
                // Обновляем видимость кнопок автозапуска
                updateAutostartButtons(!!sv.enabled);
            });
        }
        poll.add(updateLive,2);
        setTimeout(updateLive,100);
        return m.render();
    }
});
JSEOF

    cat << 'EOF' > "$YarrLuciSource"/usr/share/rpcd/acl.d/luci-app-yarr.json
{
    "luci-app-yarr": {
        "description": "Yarr LuCI access",
        "read":  { "uci":["yarr"], "ubus":{ "yarr":["load","status","version_bin","db_info","log_read","opml_export","list_mounts"] } },
        "write": { "uci":["yarr"], "ubus":{ "yarr":["service"] } }
    }
}
EOF

    cat << 'EOF' > "$YarrLuciSource"/usr/share/luci/menu.d/luci-app-yarr.json
{
    "admin/services/yarr": {
        "title": "Yarr",
        "action": { "type": "view", "path": "yarr" },
        "depends": { "acl": ["luci-app-yarr"], "uci": { "yarr": true } }
    }
}
EOF

    cat << 'EOF' > "$YarrLuciSource"/CONTROL/postinst
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF
    cat << 'EOF' > "$YarrLuciSource"/CONTROL/prerm
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << EOF > "$YarrLuciSource"/CONTROL/control
Package: luci-app-yarr
Version: 1.0
Depends: yarr, luci-base, rpcd
Source: feeds/packages/luci-app-yarr
SourceName: luci-app-yarr
License: MIT
Section: luci
Architecture: all
URL: https://github.com/nkanaev/yarr
Maintainer: nkanaev
Description: LuCI interface for Yarr RSS reader with service control, live logs, OPML export.
EOF

    chmod +x "$YarrLuciSource"/CONTROL/postinst "$YarrLuciSource"/CONTROL/prerm
    echo "Сборка luci-app-yarr…"
    LC_ALL=C ./ipkg-build "$YarrLuciSource/"
}

compileYarrI18n() {
    local LUCI_BASE="https://raw.githubusercontent.com/openwrt/luci/master/modules/luci-base/src"
    mkdir -p po2lmo-src/lib po2lmo-src/contrib
    curl -Ls -o po2lmo-src/po2lmo.c "$LUCI_BASE/po2lmo.c"
    curl -Ls -o po2lmo-src/lib/lmo.c "$LUCI_BASE/lib/lmo.c"
    curl -Ls -o po2lmo-src/lib/lmo.h "$LUCI_BASE/lib/lmo.h"
    curl -Ls -o po2lmo-src/lib/plural_formula.y "$LUCI_BASE/lib/plural_formula.y"
    curl -Ls -o po2lmo-src/contrib/lemon.c "$LUCI_BASE/contrib/lemon.c"
    curl -Ls -o po2lmo-src/contrib/lempar.c "$LUCI_BASE/contrib/lempar.c"
    cd po2lmo-src
    gcc -std=gnu17 -o contrib/lemon contrib/lemon.c >/dev/null 2>&1
    ./contrib/lemon -q lib/plural_formula.y >/dev/null 2>&1
    gcc -c -o po2lmo.o po2lmo.c
    gcc -c -o lib/lmo.o lib/lmo.c -I. -DNDEBUG
    gcc -c -o lib/plural_formula.o lib/plural_formula.c -DNDEBUG
    gcc -o po2lmo po2lmo.o lib/lmo.o lib/plural_formula.o
    cp po2lmo ../po2lmo
    cd ..
    mkdir -p po/ru "$YarrI18nSource"/usr/lib/lua/luci/i18n "$YarrI18nSource"/CONTROL

    cat << 'POEOF' > po/ru/yarr.po
msgid ""
msgstr ""
"Project-Id-Version: luci-app-yarr\n"
"Language: ru\n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Content-Transfer-Encoding: 8bit\n"

msgid "Lightweight web-based RSS aggregator with SQLite, OPML import/export, dark theme, full-text search."
msgstr "Лёгкий веб-агрегатор RSS с SQLite, импортом/экспортом OPML, тёмной темой и полнотекстовым поиском."
msgid "Storage & Database"
msgstr "Хранилище и база данных"
msgid "Storage location for database"
msgstr "Расположение хранилища для базы данных"
msgid "RAM (/tmp/yarr)"
msgstr "ОЗУ (/tmp/yarr)"
msgid "ROM (/etc/yarr)"
msgstr "ПЗУ (/etc/yarr)"
msgid "Custom path"
msgstr "Пользовательский путь"
msgid "RAM (Temporary Storage)"
msgstr "ОЗУ (временное хранилище)"
msgid "Data is stored in RAM (/tmp/yarr)."
msgstr "Данные хранятся в ОЗУ (/tmp/yarr)."
msgid "Pros:"
msgstr "Преимущества:"
msgid "High speed, no wear on router flash memory."
msgstr "Высокая скорость, отсутствие износа flash-памяти роутера."
msgid "Cons:"
msgstr "Недостатки:"
msgid "All data will be lost on reboot."
msgstr "Все данные будут потеряны при перезагрузке."
msgid "ROM (Persistent Storage)"
msgstr "ROM (постоянное хранилище)"
msgid "Data is stored in router internal memory (/etc/yarr)."
msgstr "Данные хранятся во внутренней памяти роутера (/etc/yarr)."
msgid "Data persists across reboots."
msgstr "Данные сохраняются между перезагрузками."
msgid "Frequent writes may wear out flash memory."
msgstr "Частые записи могут изнашивать flash-память."
msgid "Custom Path"
msgstr "Пользовательский путь"
msgid "Stored in any permitted folder."
msgstr "Хранится в любой разрешённой папке."
msgid "You can use external storage."
msgstr "Вы можете использовать внешнее хранилище."
msgid "Requires careful path selection."
msgstr "Требует тщательного выбора пути."
msgid "Custom database path"
msgstr "Пользовательский путь к базе данных"
msgid "Absolute path to the database file."
msgstr "Абсолютный путь к файлу базы данных."
msgid "Browse Available Drives"
msgstr "Обзор доступных дисков"
msgid "Select Storage Location"
msgstr "Выбор расположения хранилища"
msgid "Select a mounted drive for Yarr storage."
msgstr "Выберите смонтированный накопитель для хранилища Yarr."
msgid "Loading available mounts…"
msgstr "Загрузка доступных накопителей…"
msgid "No mounted drives found."
msgstr "Смонтированные накопители не найдены."
msgid "Path"
msgstr "Путь"
msgid "Size"
msgstr "Размер"
msgid "Available"
msgstr "Доступно"
msgid "Used"
msgstr "Использовано"
msgid "Action"
msgstr "Действие"
msgid "Select"
msgstr "Выбрать"
msgid "Storage path set to:"
msgstr "Путь хранилища установлен в:"
msgid "Click \"Save & Apply\" to confirm."
msgstr "Нажмите \"Сохранить и применить\" для подтверждения."
msgid "Failed to load mounts:"
msgstr "Не удалось загрузить список накопителей:"
msgid "Service Status"
msgstr "Состояние службы"
msgid "Yarr Service"
msgstr "Служба Yarr"
msgid "Running"
msgstr "Запущен"
msgid "Stopped"
msgstr "Остановлен"
msgid "Version:"
msgstr "Версия:"
msgid "Web UI:"
msgstr "Веб-интерфейс:"
msgid "Listen addr:"
msgstr "Адрес:"
msgid "Auth method:"
msgstr "Метод аутентификации:"
msgid "Process"
msgstr "Процесс"
msgid "PID:"
msgstr "PID:"
msgid "User:"
msgstr "Пользователь:"
msgid "Uptime:"
msgstr "Время работы:"
msgid "RAM (RSS):"
msgstr "ОЗУ (RSS):"
msgid "CPU:"
msgstr "ЦП:"
msgid "Command:"
msgstr "Команда:"
msgid "Database"
msgstr "База данных"
msgid "Path:"
msgstr "Путь:"
msgid "Size:"
msgstr "Размер:"
msgid "N/A"
msgstr "Н/Д"
msgid "Starting the service"
msgstr "Запуск службы"
msgid "Start"
msgstr "Запустить"
msgid "Restarting the service"
msgstr "Перезапуск службы"
msgid "Restart"
msgstr "Перезапустить"
msgid "Stopping the service"
msgstr "Остановка службы"
msgid "Stop"
msgstr "Остановить"
msgid "Autostart of the service"
msgstr "Автозапуск службы"
msgid "Enabled"
msgstr "Включено"
msgid "Disabled"
msgstr "Выключено"
msgid "Autostart enabled."
msgstr "Автозапуск включён."
msgid "Autostart disabled."
msgstr "Автозапуск выключен."
msgid "Failed to enable autostart:"
msgstr "Не удалось включить автозапуск:"
msgid "Failed to disable autostart:"
msgstr "Не удалось выключить автозапуск:"
msgid "System Log"
msgstr "Системный лог"
msgid "System log (logread)"
msgstr "Системный лог"
msgid "Application Log"
msgstr "Лог приложения"
msgid "Application log"
msgstr "Лог приложения"
msgid "Export OPML"
msgstr "Экспорт OPML"
msgid "OPML exported to:"
msgstr "OPML экспортирован в:"
msgid "Download the file via SSH:"
msgstr "Скачайте файл по SSH:"
msgid "OPML Export"
msgstr "Экспорт OPML"
msgid "Start Live Tail"
msgstr "Запустить Live Tail"
msgid "Stop Live Tail"
msgstr "Остановить Live Tail"
msgid "Log empty."
msgstr "Лог пуст."
msgid "Close"
msgstr "Закрыть"
msgid "Configuration"
msgstr "Конфигурация"
msgid "Listen address"
msgstr "Адрес прослушивания"
msgid "IP:PORT (e.g. 0.0.0.0:7070 for all interfaces or 192.168.1.1:7070 for specific IP). Warning: 0.0.0.0 makes yarr accessible from all network interfaces. Enable authentication if exposed to untrusted networks."
msgstr "IP:ПОРТ (например 0.0.0.0:7070 для всех интерфейсов или 192.168.1.1:7070 для конкретного IP). Предупреждение: 0.0.0.0 делает yarr доступным со всех сетевых интерфейсов. Включите аутентификацию, если сервис доступен из недоверенных сетей."
msgid "Write log to file"
msgstr "Записывать лог в файл"
msgid "Log file path"
msgstr "Путь к файлу лога"
msgid "Authentication"
msgstr "Аутентификация"
msgid "None"
msgstr "Нет"
msgid "Basic (user/pass)"
msgstr "Basic (логин/пароль)"
msgid "Auth file"
msgstr "Файл аутентификации"
msgid "Username"
msgstr "Имя пользователя"
msgid "Password"
msgstr "Пароль"
msgid "Auth file path"
msgstr "Путь к файлу аутентификации"
msgid "File with username:password, mode 600."
msgstr "Файл с username:password, права 600."
msgid "Base path"
msgstr "Базовый путь"
msgid "E.g. /yarr/. Empty = root."
msgstr "Напр. /yarr/. Пусто = корень."
msgid "SSL certificate"
msgstr "SSL-сертификат"
msgid "PEM fullchain for HTTPS."
msgstr "PEM fullchain для HTTPS."
msgid "SSL key"
msgstr "SSL-ключ"
msgid "PEM private key."
msgstr "PEM приватный ключ."
POEOF

    ./po2lmo po/ru/yarr.po "$YarrI18nSource"/usr/lib/lua/luci/i18n/yarr.ru.lmo

    cat << 'EOF' > "$YarrI18nSource"/CONTROL/postinst
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF
    cat << 'EOF' > "$YarrI18nSource"/CONTROL/prerm
#!/bin/sh
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << EOF > "$YarrI18nSource"/CONTROL/control
Package: luci-i18n-yarr-ru
Version: 1.0
Depends: luci-app-yarr
Source: feeds/packages/luci-app-yarr
SourceName: luci-app-yarr
License: MIT
Section: luci
Architecture: all
URL: https://github.com/nkanaev/yarr
Maintainer: nkanaev
Description: Russian translation for luci-app-yarr
EOF

    echo "Сборка luci-i18n-yarr-ru…"
    LC_ALL=C ./ipkg-build "$YarrI18nSource/"
}

# ================= MAIN =================
echo "Загрузка ipkg-build…"
curl -Ls -O "https://github.com/openwrt/openwrt/raw/refs/heads/main/scripts/ipkg-build"
chmod +x ./ipkg-build

echo "Получение информации о последней версии yarr…"
TMP_JSON=$(mktemp /tmp/yarr_release_XXXXXX.json)
curl -Lsf -o "$TMP_JSON" "https://api.github.com/repos/nkanaev/yarr/releases/latest"

if [ ! -s "$TMP_JSON" ]; then
    echo "Ошибка: не удалось получить информацию о релизе. Возможно, превышен лимит GitHub API."
    rm -f "$TMP_JSON" ./ipkg-build
    exit 1
fi

LatestRelease=$(jq -r '.tag_name' "$TMP_JSON")
if [ -z "$LatestRelease" ] || [ "$LatestRelease" = "null" ]; then
    echo "Ошибка: не удалось определить версию."
    rm -f "$TMP_JSON" ./ipkg-build
    exit 1
fi
echo "Версия yarr: $LatestRelease"

linux_assets=$(jq -r '.assets[].name | select(test("yarr_linux_.*\\.zip$"))' "$TMP_JSON")
rm -f "$TMP_JSON"

if [ -z "$linux_assets" ]; then
    echo "Ошибка: не найдено ни одной Linux-сборки в релизе."
    rm -f ./ipkg-build
    exit 1
fi

build_arch() {
    local arch_go="$1"
    local arch_openwrt="$2"
    architecture="$arch_go"
    PackageArchitectures="$arch_openwrt"
    mkdir -p "$YarrSource"
    if ! DownloadVersion; then
        echo "Пропуск архитектуры $arch_go из-за ошибки загрузки."
        rm -rf "$YarrSource"
        return 1
    fi
    for PackageArchitecture in $PackageArchitectures; do
        compileYarr
    done
    rm -rf "$YarrSource"
}

for asset in $linux_assets; do
    arch_go=$(echo "$asset" | sed -E 's/yarr_linux_(.*)\.zip/\1/')
    case "$arch_go" in
        amd64)
            build_arch "amd64" "x86_64"
            ;;
        arm64)
            build_arch "arm64" "aarch64_generic aarch64_armv8-a aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76"
            ;;
        armv7|arm)
            build_arch "armv7" "arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3 arm_cortex-a9_vfpv3-d16 arm_cortex-a15_neon-vfpv4 arm_cortex-a53_neon-vfpv4 arm_xscale arm_arm926ej-s arm_fa526"
            ;;
        386|i386)
            build_arch "386" "i386_geode i386_i486 i386_pentium4 i386_pentium-mmx"
            ;;
        *)
            echo "Неизвестная архитектура в релизе: $arch_go (пропуск)"
            ;;
    esac
done

compileYarrLuci
compileYarrI18n

# ==========================================
# ЦЕНТРАЛИЗОВАННАЯ ОЧИСТКА ВРЕМЕННЫХ ФАЙЛОВ
# ==========================================
echo "Очистка временных файлов сборки..."
rm -rf "$YarrSource" "$YarrLuciSource" "$YarrI18nSource"
rm -rf po2lmo-src po2lmo po
rm -f ./ipkg-build ./upx

echo ""
echo "✅ Сборка завершена. В директории остались только IPK-файлы:"
ls -1 *.ipk 2>/dev/null

while true; do
    read -rp "Удалить скрипт $0? [Д/н]: " answer
    case "$answer" in
        ""|Д|д|Да|да|Y|y|Yes|yes) rm -f "$0"; exit 0 ;;
        Н|н|Нет|нет|N|n|No|no) exit 0 ;;
        *) echo "Неверный ввод."; continue ;;
    esac
done
