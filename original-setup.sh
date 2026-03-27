#!/bin/bash

# ==================
# == 環境設定 ==
# ==================

# 実行環境を判定し、sed -i の差異を吸収する
# ref: https://github.com/lobehub/lobe-chat/pull/5247
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    SED_INPLACE_ARGS=('-i' '')
else
    # macOS 以外
    SED_INPLACE_ARGS=('-i')
fi

# =========================
# == 引数の初期化と解析 ==
# =========================

# 引数の既定値
# -l / --lang: 表示言語。既定値は日本語
LANGUAGE="ja_JP"

# --url: ファイルのダウンロード元
SOURCE_URL="https://raw.githubusercontent.com/lobehub/lobe-chat/main"

# --host: デプロイ先のホスト
HOST=""

usage() {
    echo "使い方: $0 [-l 言語|--lang 言語] [--url 取得元URL] [--host ホスト名またはIP]" >&2
    echo "対応言語: ja_JP, en_US, zh_CN" >&2
}

# 引数を解析する
while getopts "l:-:" opt; do
    case $opt in
        l)
            LANGUAGE=$OPTARG
        ;;
        -)
            case "${OPTARG}" in
                lang)
                    LANGUAGE="${!OPTIND}"
                    OPTIND=$(($OPTIND + 1))
                ;;
                url)
                    SOURCE_URL="${!OPTIND}"
                    OPTIND=$(($OPTIND + 1))
                ;;
                host)
                    HOST="${!OPTIND}"
                    OPTIND=$(($OPTIND + 1))
                ;;
                *)
                    usage
                    exit 1
                ;;
            esac
        ;;
        *)
            usage
            exit 1
        ;;
    esac
done

#######################
## 補助関数 ##
#######################

# 入力された言語コードを内部表現に正規化する
normalize_language() {
    case "$1" in
        ja | ja_JP | ja-JP)
            echo "ja_JP"
        ;;
        en | en_US | en-US)
            echo "en_US"
        ;;
        zh | zh_CN | zh-CN)
            echo "zh_CN"
        ;;
        *)
            echo "ja_JP"
        ;;
    esac
}

# 言語ごとのメッセージを表示する
show_message() {
    local key="$1"
    case $key in
        choose_language)
            case $LANGUAGE in
                zh_CN)
                    echo "请选择语言:"
                    echo "(0) 日本語"
                    echo "(1) English"
                    echo "(2) 简体中文"
                ;;
                en_US)
                    echo "Please choose a language:"
                    echo "(0) Japanese"
                    echo "(1) English"
                    echo "(2) Simplified Chinese"
                ;;
                *)
                    echo "表示言語を選択してください:"
                    echo "(0) 日本語"
                    echo "(1) English"
                    echo "(2) 简体中文"
                ;;
            esac
        ;;
        downloading)
            case $LANGUAGE in
                zh_CN)
                    echo "正在下载文件..."
                ;;
                en_US)
                    echo "Downloading files..."
                ;;
                *)
                    echo "ファイルをダウンロードしています..."
                ;;
            esac
        ;;
        extracted_success)
            case $LANGUAGE in
                zh_CN)
                    echo " 解压成功到目录："
                ;;
                en_US)
                    echo " extracted successfully to directory: "
                ;;
                *)
                    echo " の展開に成功しました。出力先: "
                ;;
            esac
        ;;
        extracted_failed)
            case $LANGUAGE in
                zh_CN)
                    echo " 解压失败。"
                ;;
                en_US)
                    echo " extraction failed."
                ;;
                *)
                    echo " の展開に失敗しました。"
                ;;
            esac
        ;;
        file_not_exists)
            case $LANGUAGE in
                zh_CN)
                    echo " 不存在。"
                ;;
                en_US)
                    echo " does not exist."
                ;;
                *)
                    echo " が存在しません。"
                ;;
            esac
        ;;
        security_secrect_regenerate)
            case $LANGUAGE in
                zh_CN)
                    echo "重新生成安全密钥..."
                ;;
                en_US)
                    echo "Regenerate security secrets..."
                ;;
                *)
                    echo "セキュリティシークレットを再生成しています..."
                ;;
            esac
        ;;
        security_secrect_regenerate_failed)
            case $LANGUAGE in
                zh_CN)
                    echo "无法重新生成安全密钥："
                ;;
                en_US)
                    echo "Failed to regenerate security secrets: "
                ;;
                *)
                    echo "セキュリティシークレットの再生成に失敗しました: "
                ;;
            esac
        ;;
        host_regenerate)
            case $LANGUAGE in
                zh_CN)
                    echo "✔️ 已更新部署模式配置"
                ;;
                en_US)
                    echo "✔️ Updated deployment mode configuration"
                ;;
                *)
                    echo "✔️ デプロイ設定を更新しました"
                ;;
            esac
        ;;
        host_regenerate_failed)
            case $LANGUAGE in
                zh_CN)
                    echo "无法重新生成服务器域名："
                ;;
                en_US)
                    echo "Failed to regenerate server host: "
                ;;
                *)
                    echo "サーバーホストの更新に失敗しました: "
                ;;
            esac
        ;;
        security_secrect_regenerate_report)
            case $LANGUAGE in
                zh_CN)
                    echo "安全密钥生成结果如下："
                ;;
                en_US)
                    echo "Security secret generation results are as follows:"
                ;;
                *)
                    echo "生成されたシークレットは次のとおりです:"
                ;;
            esac
        ;;
        tips_download_failed)
            case $LANGUAGE in
                zh_CN)
                    echo "$2 下载失败，请检查网络连接。"
                ;;
                en_US)
                    echo "$2 Download failed, please check the network connection."
                ;;
                *)
                    echo "$2 のダウンロードに失敗しました。ネットワーク接続を確認してください。"
                ;;
            esac
        ;;
        tips_already_installed)
            case $LANGUAGE in
                zh_CN)
                    echo "检测到您已经运行过 LobeHub，本安装程序只能完成初始化配置，并不能重复安装。如果你需要重新安装，请删除 data 和 s3_data 文件夹。"
                ;;
                en_US)
                    echo "It is detected that you have run LobeHub. This installation program can only complete the initialization configuration and cannot be reinstalled. If you need to reinstall, please delete the data and s3_data folders."
                ;;
                *)
                    echo "LobeHub はすでに初期化済みのようです。このセットアップスクリプトは再インストールには対応していません。再インストールする場合は data と s3_data フォルダを削除してください。"
                ;;
            esac
        ;;
        tips_run_command)
            case $LANGUAGE in
                zh_CN)
                    echo "您已经完成了所有配置。请运行以下命令启动 LobeHub 尝试启动："
                ;;
                en_US)
                    echo "You have completed all configurations. Please run this command to start LobeHub:"
                ;;
                *)
                    echo "設定が完了しました。LobeHub を起動するには次のコマンドを実行してください:"
                ;;
            esac
        ;;
        tips_if_want_searxng_logs)
            case $LANGUAGE in
                zh_CN)
                    echo "在上述命令中已屏蔽 SearXNG 的日志。如果你想查看 SearXNG 的日志，可以去除选项： --no-attach searxng 或运行以下命令："
                ;;
                en_US)
                    echo "In the above command, the logs of SearXNG are blocked by default. If you want to view the logs of SearXNG, you can remove the option: --no-attach searxng or run the following command:"
                ;;
                *)
                    echo "上記コマンドでは SearXNG のログを表示しません。SearXNG のログを確認したい場合は `--no-attach searxng` を外すか、次のコマンドを実行してください:"
                ;;
            esac
        ;;
        tips_if_run_normally)
            case $LANGUAGE in
                zh_CN)
                    echo "如果一切运行正常，你可以使用以下指令在 daemon 模式下启动 LobeHub:"
                ;;
                en_US)
                    echo "If everything runs normally, you can use the following command to start LobeHub in daemon mode:"
                ;;
                *)
                    echo "正常に動作することを確認できたら、次のコマンドでデーモンモード起動できます:"
                ;;
            esac
        ;;
        tips_regen_jwks)
            case $LANGUAGE in
                zh_CN)
                    echo "在完成部署测试后，请前往 https://lobehub.com/zh/docs/self-hosting/environment-variables/auth#jwks_key 生成新的 JWKS_KEY 并替换 .env 中的值，以确保安全性。"
                ;;
                en_US)
                    echo "After completing the deployment test, please go to https://lobehub.com/docs/self-hosting/environment-variables/auth#jwks_key to generate a new JWKS_KEY and replace the value in .env to ensure security."
                ;;
                *)
                    echo "デプロイ確認後は https://lobehub.com/docs/self-hosting/environment-variables/auth#jwks_key を参照して新しい JWKS_KEY を生成し、\`.env\` の値を置き換えてください。"
                ;;
            esac
        ;;
        tips_disable_registration)
            case $LANGUAGE in
                zh_CN)
                    echo "如需限制用户注册，可在 .env 中配置："
                    echo "  - 使用 SSO 登录时，设置 AUTH_DISABLE_EMAIL_PASSWORD=1 可禁用邮箱密码注册"
                    echo "  - 使用邮箱密码登录时，设置 AUTH_ALLOWED_EMAILS=user1@example.com,user2@example.com 可限制允许登录的邮箱"
                ;;
                en_US)
                    echo "To restrict user registration, configure in .env:"
                    echo "  - For SSO login: set AUTH_DISABLE_EMAIL_PASSWORD=1 to disable email/password registration"
                    echo "  - For email/password login: set AUTH_ALLOWED_EMAILS=user1@example.com,user2@example.com to allow specific emails"
                ;;
                *)
                    echo "ユーザー登録を制限したい場合は \`.env\` で次を設定できます:"
                    echo "  - SSO ログイン時: AUTH_DISABLE_EMAIL_PASSWORD=1 を設定するとメールアドレス / パスワード登録を無効化できます"
                    echo "  - メールアドレス / パスワードログイン時: AUTH_ALLOWED_EMAILS=user1@example.com,user2@example.com を設定すると許可したメールだけがログインできます"
                ;;
            esac
        ;;
        tips_show_documentation)
            case $LANGUAGE in
                zh_CN)
                    echo "完整的环境变量在'.env'中可以在文档中找到："
                ;;
                en_US)
                    echo "Full environment variables in the '.env' can be found at the documentation on "
                ;;
                *)
                    echo "\`.env\` で利用できる環境変数の一覧:"
                ;;
            esac
        ;;
        tips_show_documentation_url)
            case $LANGUAGE in
                zh_CN)
                    echo "https://lobehub.com/zh/docs/self-hosting/environment-variables"
                ;;
                en_US)
                    echo "https://lobehub.com/docs/self-hosting/environment-variables"
                ;;
                *)
                    echo "https://lobehub.com/docs/self-hosting/environment-variables"
                ;;
            esac
        ;;
        tips_no_executable)
            case $LANGUAGE in
                zh_CN)
                    echo "没有找到，请先安装。"
                ;;
                en_US)
                    echo "not found, please install it first."
                ;;
                *)
                    echo "が見つかりません。先にインストールしてください。"
                ;;
            esac
        ;;
        tips_allow_ports)
            case $LANGUAGE in
                zh_CN)
                    echo "请确保服务器以下端口未被占用且能被访问：3210, 9000, 9001"
                ;;
                en_US)
                    echo "Please make sure the following ports on the server are not occupied and can be accessed: 3210, 9000, 9001"
                ;;
                *)
                    echo "サーバーの次のポートが未使用で、外部からアクセス可能であることを確認してください: 3210, 9000, 9001"
                ;;
            esac
        ;;
        tips_auto_detected)
            case $LANGUAGE in
                zh_CN)
                    echo "已自动识别"
                ;;
                en_US)
                    echo "Auto-detected"
                ;;
                *)
                    echo "自動検出"
                ;;
            esac
        ;;
        tips_private_ip_detected)
            case $LANGUAGE in
                zh_CN)
                    echo "注意，当前识别到内网 IP，如果需要外部访问，请替换为公网 IP 地址"
                ;;
                en_US)
                    echo "Note that the current internal IP is detected. If you need external access, please replace it with the public IP address."
                ;;
                *)
                    echo "注意: 現在検出された IP はプライベートアドレスです。外部公開する場合はグローバル IP に置き換えてください。"
                ;;
            esac
        ;;
        tips_add_reverse_proxy)
            case $LANGUAGE in
                zh_CN)
                    echo "请在你的反向代理中完成域名到端口的映射："
                ;;
                en_US)
                    echo "Please complete the mapping of domain to port in your reverse proxy:"
                ;;
                *)
                    echo "リバースプロキシで次のドメインとポートを対応付けてください:"
                ;;
            esac
        ;;
        tips_no_docker_permission)
            case $LANGUAGE in
                zh_CN)
                    echo "WARN: 看起来当前用户没有 Docker 权限。"
                    echo "使用 'sudo usermod -aG docker $USER' 为用户分配 Docker 权限（可能需要重新启动 shell）。"
                ;;
                en_US)
                    echo "WARN: It look like the current user does not have Docker permissions."
                    echo "Use 'sudo usermod -aG docker $USER' to assign Docker permissions to the user (may require restarting shell)."
                ;;
                *)
                    echo "WARN: 現在のユーザーには Docker を操作する権限がないようです。"
                    echo "Docker 権限を付与するには 'sudo usermod -aG docker $USER' を実行してください（シェルの再起動が必要な場合があります）。"
                ;;
            esac
        ;;
        tips_init_database_failed)
            case $LANGUAGE in
                zh_CN)
                    echo "无法初始化数据库"
                ;;
                en_US)
                    echo "Failed to initialize the database."
                ;;
                *)
                    echo "データベースを初期化できませんでした。"
                ;;
            esac
        ;;
        ask_regenerate_secrets)
            case $LANGUAGE in
                zh_CN)
                    echo "是否要重新生成安全密钥？"
                ;;
                en_US)
                    echo "Do you want to regenerate security secrets?"
                ;;
                *)
                    echo "セキュリティシークレットを再生成しますか？"
                ;;
            esac
        ;;
        ask_deploy_mode)
            case $LANGUAGE in
                zh_CN)
                    echo "请选择部署模式："
                    echo "(0) 域名模式（访问时无需指明端口），需要使用反向代理服务 LobeHub, RustFS，并分别分配一个域名；"
                    echo "(1) 端口模式（访问时需要指明端口，如使用IP访问，或域名+端口访问），需要放开指定端口；"
                    echo "(2) 本地模式（仅供本地测试使用）"
                    echo "如果你对这些内容疑惑，可以先选择使用本地模式进行部署，稍后根据文档指引再进行修改。"
                    echo "https://lobehub.com/docs/self-hosting/server-database/docker-compose"
                ;;
                en_US)
                    echo "Please select the deployment mode:"
                    echo "(0) Domain mode (no need to specify the port when accessing), you need to use the reverse proxy service LobeHub, RustFS, and assign a domain name respectively;"
                    echo "(1) Port mode (need to specify the port when accessing, such as using IP access, or domain name + port access), you need to open the specified port;"
                    echo "(2) Local mode (for local testing only)"
                    echo "If you are confused about these contents, you can choose to deploy in local mode first, and then modify according to the document guide later."
                    echo "https://lobehub.com/docs/self-hosting/server-database/docker-compose"
                ;;
                *)
                    echo "デプロイモードを選択してください:"
                    echo "(0) ドメインモード: アクセス時にポート指定は不要です。LobeHub と RustFS をリバースプロキシ配下に置き、それぞれにドメインを割り当てます。"
                    echo "(1) ポートモード: IP アドレスやドメイン + ポートでアクセスします。必要なポートを開放してください。"
                    echo "(2) ローカルモード: ローカルテスト専用です。"
                    echo "迷う場合は、まずローカルモードでデプロイしてから後でドキュメントに沿って調整できます。"
                    echo "https://lobehub.com/docs/self-hosting/server-database/docker-compose"
                ;;
            esac
        ;;
        ask_host)
            case $LANGUAGE in
                zh_CN)
                    echo " 部署IP/域名"
                ;;
                en_US)
                    echo " Deploy IP/Domain"
                ;;
                *)
                    echo " デプロイ先のIP/ドメイン"
                ;;
            esac
        ;;
        ask_domain)
            case $LANGUAGE in
                zh_CN)
                    echo "服务的域名（例如 $2 ，不要包含协议前缀）："
                ;;
                en_US)
                    echo "The domain of the service (e.g. $2, do not include the protocol prefix):"
                ;;
                *)
                    echo "サービス用のドメインを入力してください（例: $2、プロトコル接頭辞は不要です）:"
                ;;
            esac
        ;;
        ask_protocol)
            case $LANGUAGE in
                zh_CN)
                    echo "域名是否使用 https 协议？ (所有服务需要使用同一协议)"
                ;;
                en_US)
                    echo "Does the domain use the https protocol? (All services need to use the same protocol)"
                ;;
                *)
                    echo "ドメインでは https を使いますか？（すべてのサービスで同じプロトコルを使ってください）"
                ;;
            esac
        ;;
        ask_init_database)
            case $LANGUAGE in
                zh_CN)
                    echo "是否初始化数据库？"
                ;;
                en_US)
                    echo "Do you want to initialize the database?"
                ;;
                *)
                    echo "データベースを初期化しますか？"
                ;;
            esac
        ;;
    esac
}

# ファイルをダウンロードする
download_file() {
    wget "$1" -O "$2"
    # 失敗したら即終了する
    if [ $? -ne 0 ]; then
        show_message "tips_download_failed" "$2"
        exit 1
    fi
}

print_centered() {
    local text="$1"                                   # 表示する文字列
    local color="${2:-reset}"                         # 色。既定値は reset
    local term_width=$(tput cols)                     # ターミナル幅
    local text_length=${#text}                        # 文字列長
    local padding=$(((term_width - text_length) / 2)) # 左側の余白

    # bash 3.x でも動く色コード
    local color_code=""
    local reset_code="\e[0m"
    case "$color" in
        black)   color_code="\e[30m" ;;
        red)     color_code="\e[31m" ;;
        green)   color_code="\e[32m" ;;
        yellow)  color_code="\e[33m" ;;
        blue)    color_code="\e[34m" ;;
        magenta) color_code="\e[35m" ;;
        cyan)    color_code="\e[36m" ;;
        white)   color_code="\e[37m" ;;
        reset)   color_code="\e[0m" ;;
        *)
            echo "無効な色が指定されました。使用可能: black red green yellow blue magenta cyan white reset"
            return 1
        ;;
    esac

    # 余白付きで中央寄せ表示
    printf "%*s${color_code}%s${reset_code}\n" $padding "" "$text"
}

# 使い方:
# ```sh
#   ask "prompt" "default" "description"
#   echo $ask_result
# ```
#   "prompt" ["description" "default"]
ask() {
    local prompt="$1"
    local default="$2"
    local description="$3"
    # 説明がある場合だけ末尾にスペースを付与する
    if [ -n "$description" ]; then
        description="$description "
    fi
    local result
    
    if [ -n "$default" ]; then
        read -p "$prompt [${description}${default}]: " result
        result=${result:-$default}
    else
        read -p "$prompt: " result
    fi
    # 前後の空白を削除してグローバル変数に格納する
    ask_result=$(echo "$result" | xargs)
}

####################
## メイン処理 ##
####################

# ==============
# == 変数定義 ==
# ==============
# ファイル一覧
SUB_DIR="docker-compose/deploy"
FILES=(
    "$SUB_DIR/docker-compose.yml"
    "$SUB_DIR/searxng-settings.yml"
    "$SUB_DIR/bucket.config.json"
)
ENV_EXAMPLES=(
    "$SUB_DIR/.env.zh-CN.example"
    "$SUB_DIR/.env.example"
)
# 既定値
RUSTFS_SECRET_KEY="YOUR_RUSTFS_PASSWORD"
RUSTFS_HOST="localhost:9000"
PROTOCOL="http"

# 表示言語を正規化する
LANGUAGE="$(normalize_language "$LANGUAGE")"

section_download_files(){
    # セットアップに必要なファイルを取得する
    if ! command -v wget &> /dev/null ; then
        echo "wget $(show_message 'tips_no_executable')"
        exit 1
    fi
    
    show_message "downloading"
    download_file "$SOURCE_URL/${FILES[0]}" "docker-compose.yml"
    download_file "$SOURCE_URL/${FILES[1]}" "searxng-settings.yml"
    download_file "$SOURCE_URL/${FILES[2]}" "bucket.config.json"
    # 指定言語に応じた .env サンプルを取得する
    if [ "$LANGUAGE" = "zh_CN" ]; then
        download_file "$SOURCE_URL/${ENV_EXAMPLES[0]}" ".env"
    else
        download_file "$SOURCE_URL/${ENV_EXAMPLES[1]}" ".env"
    fi
}
# data または s3_data があれば再初期化を避ける
if [ -d "data" ] || [ -d "s3_data" ]; then
    show_message "tips_already_installed"
    exit 0
else
    section_download_files
fi

section_configurate_host() {
    DEPLOY_MODE=$ask_result
    show_message "host_regenerate"
    # ローカルモードならこの設定は不要
    if [[ "$DEPLOY_MODE" == "2" ]]; then
        HOST="localhost:3210"
        LOBE_HOST="$HOST"
        return 0
    fi

    # ドメインモードではプロトコルを確認する
    if [[ "$DEPLOY_MODE" == "0" ]]; then
        # https を使うか確認する
        echo "$(show_message 'ask_protocol')"
        ask "(y/n)" "y"
        if [[ "$ask_result" == "y" ]]; then
            PROTOCOL="https"
            # .env 内の http を https に置き換える
            sed "${SED_INPLACE_ARGS[@]}" "s#http://#https://#" .env
        fi
    fi
    
    # sed が利用できることを確認する
    if ! command -v sed &> /dev/null ; then
        echo "sed $(show_message 'tips_no_executable')"
        exit 1
    fi
    
    # ホスト指定がなければサーバーIPを自動検出する
    if [ -z "$HOST" ]; then
        HOST=$(hostname -I | awk '{print $1}')
        # ポートモードでプライベートIPなら注意喚起する
        if [[ "$DEPLOY_MODE" == "1" ]] && ([[ "$HOST" == "192.168."* ]] || [[ "$HOST" == "172."* ]] || [[ "$HOST" == "10."* ]]); then
            echo "$(show_message 'tips_private_ip_detected')"
        fi
    fi
    
    case $DEPLOY_MODE in
        0)
            DEPLOY_MODE="domain"
            echo "LobeHub $(show_message 'ask_domain' 'example.com')"
            ask "(example.com)"
            LOBE_HOST="$ask_result"
            # ドメインモードでは RustFS 用ドメインも確認する
            echo "RustFS S3 API $(show_message 'ask_domain' 's3.example.com')"
            ask "(s3.example.com)"
            RUSTFS_HOST="$ask_result"
        ;;
        1)
            DEPLOY_MODE="ip"
            ask "LobeHub$(show_message 'ask_host')" "$HOST" "$(show_message 'tips_auto_detected')"
            LOBE_HOST="$ask_result"
            # 入力値をホストとして採用する
            HOST="$ask_result"
            # ポートモードでは各サービスのポートを付与する
            LOBE_HOST="${HOST}:3210"
            RUSTFS_HOST="${HOST}:9000"
        ;;
        *)
            echo "無効なデプロイモードです: $ask_result"
            exit 1
        ;;
    esac

    # LobeHub 側の接続先
    sed "${SED_INPLACE_ARGS[@]}" "s#^APP_URL=.*#APP_URL=$PROTOCOL://$LOBE_HOST#" .env
    # S3 関連の接続先
    sed "${SED_INPLACE_ARGS[@]}" "s#^S3_ENDPOINT=.*#S3_ENDPOINT=$PROTOCOL://$RUSTFS_HOST#" .env
    
    # .env の更新結果を確認する
    if [ $? -ne 0 ]; then
        echo "$(show_message 'host_regenerate_failed')$HOST in \`.env\`"
    fi
}
show_message "ask_deploy_mode"
ask "(0,1,2)" "2"
if [[ "$ask_result" == "0" ]] || [[ "$ask_result" == "1" ]] || [[ "$ask_result" == "2" ]]; then
    section_configurate_host
else
    echo "無効なデプロイモードです: $ask_result。0、1、2 のいずれかを選んでください。"
    exit 1
fi

# ============================
# === シークレット再生成 ===
# ============================
section_regenerate_secrets() {
    # 必要なコマンドが使えるか確認する
    if ! command -v openssl &> /dev/null ; then
        echo "openssl $(show_message 'tips_no_executable')"
        exit 1
    fi
    if ! command -v tr &> /dev/null ; then
        echo "tr $(show_message 'tips_no_executable')"
        exit 1
    fi
    if ! command -v fold &> /dev/null ; then
        echo "fold $(show_message 'tips_no_executable')"
        exit 1
    fi
    if ! command -v head &> /dev/null ; then
        echo "head $(show_message 'tips_no_executable')"
        exit 1
    fi
    
    generate_key() {
        if [[ -z "$1" ]]; then
            echo "使い方: generate_key <length>"
            return 1
        fi
        echo $(openssl rand -hex $1 | tr -d '\n' | fold -w $1 | head -n 1)
    }
    
    if ! command -v sed &> /dev/null ; then
        echo "sed $(show_message 'tips_no_executable')"
        exit 1
    fi
    echo "$(show_message 'security_secrect_regenerate')"

    # RustFS の S3 ユーザーパスワードを生成する
    RUSTFS_SECRET_KEY=$(generate_key 8)
    if [ $? -ne 0 ]; then
        echo "$(show_message 'security_secrect_regenerate_failed')RUSTFS_SECRET_KEY"
        RUSTFS_SECRET_KEY="YOUR_RUSTFS_PASSWORD"
    else
        sed "${SED_INPLACE_ARGS[@]}" "s#^RUSTFS_SECRET_KEY=.*#RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY}#" .env
        if [ $? -ne 0 ]; then
            echo "$(show_message 'security_secrect_regenerate_failed')RUSTFS_SECRET_KEY in \`.env\`"
        fi
    fi

    # KEY_VAULTS_SECRET を生成する（base64 / 32 bytes）
    KEY_VAULTS_SECRET=$(openssl rand -base64 32)
    if [ $? -ne 0 ]; then
        echo "$(show_message 'security_secrect_regenerate_failed')KEY_VAULTS_SECRET"
    else
        sed "${SED_INPLACE_ARGS[@]}" "s#^KEY_VAULTS_SECRET=.*#KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}#" .env
        if [ $? -ne 0 ]; then
            echo "$(show_message 'security_secrect_regenerate_failed')KEY_VAULTS_SECRET in \`.env\`"
        fi
    fi

    # AUTH_SECRET を生成する（base64 / 32 bytes）
    AUTH_SECRET=$(openssl rand -base64 32)
    if [ $? -ne 0 ]; then
        echo "$(show_message 'security_secrect_regenerate_failed')AUTH_SECRET"
    else
        sed "${SED_INPLACE_ARGS[@]}" "s#^AUTH_SECRET=.*#AUTH_SECRET=${AUTH_SECRET}#" .env
        if [ $? -ne 0 ]; then
            echo "$(show_message 'security_secrect_regenerate_failed')AUTH_SECRET in \`.env\`"
        fi
    fi
}

show_message "ask_regenerate_secrets"
ask "(y/n)" "y"
if [[ "$ask_result" == "y" ]]; then
    section_regenerate_secrets
fi

section_init_database() {
    if ! command -v docker &> /dev/null ; then
        echo "docker $(show_message 'tips_no_executable')"
        return 1
    fi

    if ! docker compose version &> /dev/null ; then
        echo "docker compose $(show_message 'tips_no_executable')"
        return 1
    fi

    # docker stats が失敗する場合は Docker 権限不足の可能性が高い
    # ref: https://github.com/paperless-ngx/paperless-ngx/blob/89e5c08a1fe4ca0b7641ae8fbd5554502199ae40/install-paperless-ngx.sh#L64-L72
    if ! docker stats --no-stream &> /dev/null ; then
        echo "$(show_message 'tips_no_docker_permission')"
        return 1
    fi

    docker compose pull
    docker compose up --detach postgresql
    # 低速な環境でも起動を待てるように少し待機する
    sleep 15
    docker compose stop
}

show_message "ask_init_database"
ask "(y/n)" "y"
if [[ "$ask_result" == "y" ]]; then
    # 戻り値 1 は初期化失敗を表す
    section_init_database
    if [ $? -ne 0 ]; then
        echo "$(show_message 'tips_init_database_failed')"
    fi
else 
    show_message "tips_init_database_failed"
fi

section_display_configurated_report() {
    # 最終的な設定内容を表示する
    echo "$(show_message 'security_secrect_regenerate_report')"

    echo -e "LobeHub: \n  - URL: $PROTOCOL://$LOBE_HOST"
    echo -e "RustFS: \n  - URL: $PROTOCOL://$RUSTFS_HOST \n  - ユーザー名: admin\n  - パスワード: ${RUSTFS_SECRET_KEY}\n"

    # ドメインモードではリバースプロキシ向けの対応表も表示する
    if [[ "$DEPLOY_MODE" == "domain" ]]; then
        echo "$(show_message 'tips_add_reverse_proxy')"
        printf "\n%s\t->\t%s\n" "$LOBE_HOST" "127.0.0.1:3210"
        printf "%s\t->\t%s\n" "$RUSTFS_HOST" "127.0.0.1:9000"
    fi

    # 起動手順を案内する

    printf "\n%s\n\n" "$(show_message "tips_run_command")"
    print_centered "docker compose up --no-attach searxng" "green"
    printf "\n%s\n" "$(show_message "tips_if_run_normally")"
    printf "\n%s\n" "$(show_message "tips_regen_jwks")"
    printf "\n%s\n\n" "$(show_message "tips_disable_registration")"
    print_centered "docker compose up -d --no-attach searxng" "green"
    printf "\n%s\n" "$(show_message "tips_if_want_searxng_logs")"
    print_centered "docker compose logs -f searxng" "white"
    printf "\n%s\n" "$(show_message "tips_allow_ports")"
    printf "\n%s" "$(show_message "tips_show_documentation")"
    printf "%s\n" "$(show_message "tips_show_documentation_url")"
}
section_display_configurated_report
