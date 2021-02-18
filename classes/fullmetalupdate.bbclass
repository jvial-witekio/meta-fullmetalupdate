python __anonymous() {
    import configparser
    import os

    ostree_repo = d.getVar('OSTREE_REPO')
    if not ostree_repo:
        bb.fatal("OSTREE_REPO should be set in your local.conf")

    ostree_repo = d.getVar('OSTREE_BRANCHNAME')
    if not ostree_repo:
        bb.fatal("OSTREE_BRANCHNAME should be set in your local.conf")

    config_file = d.getVar('HAWKBIT_CONFIG_FILE')
    if not config_file:
        bb.fatal("Please export/define HAWKBIT_CONFIG_FILE")

    if not os.path.isfile(config_file):
        bb.fatal("HAWKBIT_CONFIG_FILE(" + config_file + ") is not a file, please fix the path" , config_file)

    config = configparser.ConfigParser()
    config.read(config_file)

    hawkbit_vendor_name = config['client']['hawkbit_vendor_name']
    hawkbit_url_host = config['client']['hawkbit_url_host']
    hawkbit_url_port = config['client']['hawkbit_url_port']
    hawkbit_ssl = config['client'].getboolean('hawkbit_ssl', fallback=False)
    ostree_name_remote = config['ostree']['ostree_name_remote']
    ostree_gpg_verify = config['ostree'].getboolean('ostree_gpg-verify', fallback=False)
    ostree_ssl = config['ostree'].getboolean('ostree_ssl', fallback=False)
    ostree_url_host = config['ostree']['ostree_url_host']
    ostree_url_port = config['ostree']['ostree_url_port']
    ostree_url_path = config['ostree'].get('ostree_url_path', fallback='')
    ostreepush_method = config['ostree'].get('ostreepush_method', fallback='ostreepush')
    if ostreepush_method == 'ostreepush':
        ostreepush_ssh_user = config['ostree']['ostreepush_ssh_user']
        ostreepush_ssh_host = config['ostree']['ostreepush_ssh_host']
        ostreepush_ssh_port = config['ostree']['ostreepush_ssh_port']
        ostreepush_ssh_path = config['ostree']['ostreepush_ssh_path']
        ostreepush_ssh_pwd = config['ostree']['ostreepush_ssh_pwd']
        ostree_ssh_address = "ssh://" + ostreepush_ssh_user + "@" + ostreepush_ssh_host + ":" + ostreepush_ssh_port + ostreepush_ssh_path

    if hawkbit_ssl:
        hawkbit_http_address = "https://" + hawkbit_url_host + ":" + hawkbit_url_port
    else:
        hawkbit_http_address = "http://" + hawkbit_url_host + ":" + hawkbit_url_port

    if ostree_ssl:
        ostree_http_address = "https://" + ostree_url_host + ":" + ostree_url_port + ostree_url_path
    else:
        ostree_http_address = "http://" + ostree_url_host + ":" + ostree_url_port + ostree_url_path

    d.setVar('HAWKBIT_VENDOR_NAME', hawkbit_vendor_name)
    d.setVar('HAWKBIT_URL_PORT', hawkbit_url_port)
    d.setVar('HAWKBIT_SSL', hawkbit_ssl)
    d.setVar('OSTREE_OSNAME', ostree_name_remote)
    d.setVar('OSTREE_URL_PORT', ostree_url_port)
    d.setVar('OSTREEPUSH_METHOD', ostreepush_method)
    if ostreepush_method == 'ostreepush':
        d.setVar('OSTREEPUSH_SSH_PWD', ostreepush_ssh_pwd)
        d.setVar('OSTREE_SSH_ADDRESS', ostree_ssh_address)
    d.setVar('OSTREE_HTTP_ADDRESS', ostree_http_address)
    d.setVar('HAWKBIT_HTTP_ADDRESS', hawkbit_http_address)

    d.setVar('OSTREE_MIRROR_PULL_RETRIES', "10")
    d.setVar('OSTREE_MIRROR_PULL_DEPTH', "0")
    d.setVar('OSTREE_CONTAINER_PULL_DEPTH', "1")
}

ostree_init() {
    local ostree_repo="$1"
    local ostree_repo_mode="$2"

    ostree --repo=${ostree_repo} init --mode=${ostree_repo_mode}
}

ostree_init_if_non_existent() {
    local ostree_repo="$1"
    local ostree_repo_mode="$2"

    if [ ! -d ${ostree_repo} ]; then
        mkdir -p ${ostree_repo}
        ostree_init ${ostree_repo} ${ostree_repo_mode}
    fi
}

ostree_push() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    bbnote "Push the build result to the remote OSTREE using ${OSTREEPUSH_METHOD} method"
    if [ "${OSTREEPUSH_METHOD}" = "ostreepush" ]; then
        sshpass -p ${OSTREEPUSH_SSH_PWD} ostree-push --repo ${ostree_repo} ${OSTREE_SSH_ADDRESS} ${ostree_branch}
    elif [ "${OSTREEPUSH_METHOD}" = "azcopy" ]; then
        azcopy sync ${ostree_repo} "${OSTREE_HTTP_ADDRESS}" --recursive=true
    else
        bbwarn "Unknown method to push to OSTREE remote: ${OSTREEPUSH_METHOD}"
    fi
}

ostree_pull() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_depth="$3"

    ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --repo=${ostree_repo}
}

ostree_pull_mirror() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_depth="$3"
    local ostree_maxretry="$4"
    local lookup="Timeout"
    local counter_retry=0

    $(ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --mirror --repo=${ostree_repo} 2>&1 | grep -q ${lookup}) 

    while ! test $? -gt 0 && [ ${counter_retry} -le ${ostree_maxretry} ]
    do 
        counter_retry=$(expr $counter_retry + 1)
        bbnote "OsTree pull counter retry: ${counter_retry}"
        $(ostree pull ${ostree_branch} ${ostree_branch} --depth=${ostree_depth} --mirror --repo=${ostree_repo} 2>&1 | grep -q ${lookup}) 
    done

    # In case we use azcopy, we won't modify the distant configuration on the distant itself
    if [ "${OSTREEPUSH_METHOD}" = "azcopy" ]; then
        ostree_remote_delete ${ostree_repo} ${ostree_branch}
    fi
}

ostree_revparse() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    ostree rev-parse ${ostree_branch} --repo=${ostree_repo} | head
}

ostree_remote_add() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_http_address="$3"

    ostree remote add --no-gpg-verify ${ostree_branch} "${ostree_http_address}" --repo=${ostree_repo}
}

ostree_remote_delete() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    ostree remote delete ${ostree_branch} --repo=${ostree_repo}
}

ostree_is_remote_present() {
    local ostree_repo="$1"
    local ostree_branch="$2"

    ostree remote list --repo=${ostree_repo} | grep -q ${ostree_branch}
}

ostree_remote_add_if_not_present() {
    local ostree_repo="$1"
    local ostree_branch="$2"
    local ostree_http_address="$3"

    if ! ostree_is_remote_present ${ostree_repo} ${ostree_branch}; then
        ostree_remote_add ${ostree_repo} ${ostree_branch} "${ostree_http_address}"
    fi
}

curl_post() {
    local hawkbit_rest="$1"
    local hawkbit_data="$2"

    curl "${HAWKBIT_HTTP_ADDRESS}/rest/v1/softwaremodules/${hawkbit_rest}" -i -X POST --user admin:admin -H "Content-Type: application/hal+json;charset=UTF-8" -d "${hawkbit_data}"
}

hawkbit_metadata_value() {
    local key="$1"
    local value="$2"

    echo '[ { "targetVisible" : true, "value" : "'${value}'", "key" : "'${key}'" } ]'
}
