### 访问计算： https://业务IP  /  admin/xtao@123

#!/bin/bash
set +e

# Log_Path=/root/inspection
Time_Stmp=$(date +"%Y%m%d_%H%M%S")
Log_File=/root/ins_${Time_Stmp}.log



# read -p  "volume-name: "       vol_name
# read -p  "start_node_number: " start
# read -p  "end_node_count: " ending

vol_name=$(alamocli volume info | awk 'NR==1{print $1}')
echo "卷名称: $vol_name"

start=1
ending=$(alamocli ipzone info zone1 | grep -o '"Al[^"]*":' | wc -l)


echo "###############memory###################" > "${Log_File}"
for i in $(seq $start $ending); do 
    echo "node$i"
    ssh "node$i" free -h
done >> "${Log_File}" 2>&1

# free -h >> "${Log_File}" 2>&1

echo "###############volume-capacity###################" >> "${Log_File}" 2>&1
# 卷总容量和使用量
alamocli volume stat ${vol_name} >> "${Log_File}" 2>/dev/null || \
xd-alamo volume stat ${vol_name} >> "${Log_File}" 2>&1


echo "###############ipmi###################" >> "${Log_File}" 2>&1

# 系统是否健康
ipmitool -I open chassis status >> "${Log_File}" 2>&1

echo "###############pool###################"  >> "${Log_File}" 2>&1

zpool status  >> "${Log_File}" 2>&1

# pool是否健康
echo "###############zpool_status###########" >> "${Log_File}" 2>&1
for i in $(seq $start $ending); do
    echo node$i
    ssh node$i zpool status -x
done >> "${Log_File}" 2>&1


echo "###############volume###################"  >> "${Log_File}" 2>&1

# 卷是否健康
alamocli volume status  >> "${Log_File}" 2>&1
 
echo "###############metadata###################"  >> "${Log_File}" 2>&1

# metaclass的容量和使用情况
zpool get metadata_size,metadata_used ${HOSTNAME}_pool1 -H  >> "${Log_File}" 2>/dev/null || \
zpool iostat -v >> "${Log_File}" 2>&1

echo "###############NFS_NUMBER###################"  >> "${Log_File}" 2>&1

# NFS客户端的个数

alamo volume status ${vol_name} nfs client |grep Clients  >> "${Log_File}" 2>/dev/null || \
gluster  volume status ${vol_name} nfs client |grep Clients >> "${Log_File}" 2>&1



echo "###############smb###################"  >> "${Log_File}" 2>&1

docker ps  >> "${Log_File}" 2>&1

echo "###############smb-number ###################"  >> "${Log_File}" 2>&1
for i in $(seq $start $ending); do
    echo node$i
    ssh node$i pgrep smbd | wc -l
done >> "${Log_File}" 2>&1


echo "###############quota#####################"  >> "${Log_File}" 2>&1
# 系统配额使用情况
stdbuf -o0 alamocli quota list  ${vol_name} >> "${Log_File}" 2>&1  || \
alamocli quota list  ${vol_name} >> "${Log_File}" 2>&1

echo "###############Haagent###################"  >> "${Log_File}" 2>&1
# Haagent服务是否正常
systemctl status Haagent >> "${Log_File}" 2>&1

echo "###############ntpd###################"  >> "${Log_File}" 2>&1
# ntpd服务是否正常
systemctl status ntpd >> "${Log_File}" 2>&1

echo "###############disk-number###################"  >> "${Log_File}" 2>&1
# 硬盘数量
for i in $(seq $start $ending); do
    echo node$i
    ssh node$i lsscsi -sg | wc -l
done >> "${Log_File}" 2>&1

echo "###############disk-number###################"  >> "${Log_File}" 2>&1
for i in $(seq $start $ending); do
    echo node$i
    ssh node$i alamocli enclosure list
done >> "${Log_File}" 2>&1


####################################################################################################

#! /usr/bin/env bash

set -eou pipefail

INFO_LOG_FILE=report.info
RKEY=""

insert_deli() {
    echo "========================================================================"
}

section_deli() {
    echo "------------------------------------------------------------------------"
}

get_rkey() {
    local rkey=""
    for i in $(seq 0 ${#HOSTNAME}); do
        rkey=$((rkey + $(printf "%d" \'"${HOSTNAME:${i}:1}")))
    done

    echo "0x${rkey}"
}

is_alamo() {
    if command -v "alamo" >/dev/null; then
        echo "1"
        return
    fi

    echo "0"
}

is_my_disk() {
    local disk=$1
    local info=""
    local disk_key=""
    info=$(sg_persist --no-inquiry --in --read-reservation --device="${disk}" 2>/dev/null)
    disk_key=$(grep Key <<<"${info}" | awk -F= '{print $2}')
    if [[ ${disk_key} == "${RKEY}" ]]; then
        return 0
    fi

    return 1
}

check_is_ok() {
    local service=$1
    local name=$2

    if eval "${service}"; then
        printf "%-14s: %b\n" "${name}" "OK"
    else
        printf "%-14s: %b\n" "${name}" "NOT OK"
    fi
}

check_zpool() {
    section_deli

    local status=""
    local tmpfile=""

    tmpfile=$(mktemp)
    zpool status -x >"${tmpfile}" 2>&1
    if [[ "all pools are healthy" == $(cat "${tmpfile}") ]]; then
        echo "Pool status:"
        echo "all pools are healthy"
        return 0
    fi

    {
        num_re='^[0-9]+$'
        while read -r line; do
            IFS=" " read -ra segs <<<"${line}"
            if [[ ${#segs[@]} -lt 5 ]]; then
                continue
            fi

            if [[ "${segs[2]}" =~ $num_re && ${segs[2]} -ne 0 ]]; then
                echo "READ Error occured on ${segs[0]}"
            fi
            if [[ "${segs[3]}" =~ $num_re && ${segs[3]} -ne 0 ]]; then
                echo "WRITE Error occured on ${segs[0]}"
            fi
            if [[ "${segs[4]}" =~ $num_re && ${segs[4]} -ne 0 ]]; then
                echo "CHECKSUM Error occured on ${segs[0]}"
            fi
        done <"${tmpfile}"
    } >&2
    return 1
}

check_pool_capacity() {
    section_deli
    echo "Pool Capacity:"
    df -h | grep pool
}

check_log_capacity() {
    section_deli
    echo "Log Capacity:"
    used=$(df -h /var/log --output=pcent | tail -n 1)
    echo "Log capacity is used: ${used}"
}

check_ctdb_status() {
    section_deli
    if [[ $(docker container inspect -f "{{.State.Status}}" smbd) != "running" ]]; then
        echo "Smbd container is not ok" >&2
        return 1
    fi

    ctdb_status=$(docker exec -t smbd ctdb nodestatus | awk '{print $3}')
    if [[ ${ctdb_status} == "OK" ]]; then
        return 0
    else
        echo "CTDB status is not ok" >&2
        return 1
    fi
}

check_smbd_count() {
    section_deli
    echo "SMBD COUNT:"
    smbd_count=$(pgrep smbd | wc -l)
    if [[ ${smbd_count} -gt 200 ]]; then
        echo "Too many smbd process: ${smbd_count}"
    else
        echo "Smbd process count is: ${smbd_count}"
    fi
}

check_ntp() {
    section_deli
    if ntpstat >/dev/null; then
        return 0
    else
        return 1
    fi
}

check_memory() {
    section_deli
    echo "Memory Info:"
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    echo "Available Memory is $((available / 1024 / 1024))G"
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo "Total Memory is $((total / 1024 / 1024))G"
    used_percentage=$(free -m | awk 'NR==2 {print ($3/$2)*100}')
    echo "Used Memory Percentage is ${used_percentage}%"
}

check_high_memory_process() {
    section_deli
    echo "Top 10 process which take up the most memory:"
    top -o RES -b -n 2 | head -n 17 | tail -n 11
}

check_cpu() {
    section_deli
    echo "CPU Info:"
    top_output=$(top -bn1)
    cpu_usage=$(echo "$top_output" | awk 'NR==3 {print $2}')
    echo "CPU Usage: ${cpu_usage}%"
}

check_volume_status() {
    section_deli
    local cmd=""
    if [[ $(is_alamo) -eq 1 ]]; then
        cmd="alamo"
    else
        cmd="gluster"
    fi

    for vol in $(${cmd} volume list); do
        output=$(alamocli volume status -n "${vol}" -j 2>/dev/null)
        if [[ $(grep "healthy" <<<"${output}" | awk '{print $2}') == "\"Health\"" ]]; then
            continue
        else
            echo "${output}" >&2
            return 1
        fi
    done

    return 0
}

check_volume_capacity() {
    section_deli
    local cmd=""
    if [[ $(is_alamo) -eq 1 ]]; then
        cmd="alamo"
    else
        cmd="gluster"
    fi
    echo "Volume Stat:"
    for vol in $(${cmd} volume list); do
        alamocli volume stat "${vol}"
    done
}

check_quota() {
    section_deli
    local cmd=""
    if [[ $(is_alamo) -eq 1 ]]; then
        cmd="alamo"
    else
        cmd="gluster"
    fi
    echo "Quota list:"
    for vol in $(${cmd} volume list); do
        alamocli quota list "${vol}"
    done
}


check_load_avg() {
    section_deli
    echo "Load Average: $(uptime)"
}

check_disk_count() {
    section_deli
    local count=0

    count=$(lsscsi -ws | grep -c disk)
    echo "Disk count is: ${count}"
}

check_disk_status() {
    section_deli
    local disk=""
    local status=""
    local ok=""

    disks=$(lsscsi -ws | grep disk | awk '{print $4}')
    for disk in ${disks}; do
        if ! is_my_disk "${disk}"; then
            continue
        fi
        smartctl -a "${disk}" >/dev/null
        status=$?
        if [[ ${status} -eq 0 ]]; then
            continue
        fi

        echo "disk ${disk} have error: ${status}" >&2
        echo "Try to locate disk: $(alamocli disk locate -m "${disk}")" >&2
        if [[ -z ${ok} ]]; then
            ok="e"
        fi
    done

    if [[ -n ${ok} ]]; then
        return 1
    fi

    return 0
}

check_etcd() {
    section_deli
    if ! systemctl cat etcd >/dev/null 2>&1; then
        return 0
    fi

    local state=()
    IFS='=' read -ra state -d '' <<<"$(systemctl show etcd --property=ActiveState)"
    if [[ "active" == "${state[1]}" ]]; then
        echo "Host ${HOSTNAME}'s etcd service is not alive" >&2
        return 1
    fi

    status=$(docker exec -it etcd etcdctl endpoint health --cluster)
    if [[ $? -ne 0 ]]; then
        echo "etcd is not healthy" >&2
        echo "${status}" >&2
        return 1
    fi

    return 0
}

check_ipzone() {
    section_deli
    echo "IPZONE STATUS:"
    for i in $(alamocli ipzone list); do
        alamocli ipzone status "${i}"
    done
}

check_ssd() {
    section_deli
    echo "SSD ENDURANCE INFO:"
    ssds=$(alamocli disk list | grep SSD | awk '{print $10}')

    for i in ${ssds}; do
        if ! is_my_disk "${i}"; then
            continue
        fi
        percent=$(smartctl -a "${i}" | grep endurance | awk -F: '{print $2}')
        echo "SSD ${i} used endurance indicator: ${percent}"
    done
}

check_hardware() {
    section_deli
    echo "HARDWARE INFO:"
    journalctl -p err -k -o short-precise -x --no-pager | grep "Hardware Error"
}

check_metadata() {
    section_deli
    echo "METADATA CAP INFO:"
    zpool get all |grep metadata
}

check_disk_glitch() {
    section_deli
    echo "Disk glitch info:"
    grep "removi" /var/log/messages >&2
}

check_volume_log() {
    section_deli
    echo "VOLUME LOG:"
    local path=""
    if [[ $(is_alamo) -eq 1 ]]; then
        path=alamofs
    else
        path=glusterfs
    fi

    echo "  NFS disconnect log:"
    tail -n 20000 /var/log/${path}/nfs.log | grep DISC | grep -v 0-socket.nfs-server
    echo "  NFS error log:"
    tail -n 20000 /var/log/${path}/nfs.log | grep -E " C | E | W "

    echo "  BRICK error log:"
    tail -n 20000 /var/log/${path}/bricks/data-${HOSTNAME}*.log | grep -E " C | E "
}

check_haagent_log() {
    section_deli
    echo "Haagent log:"
    tail -n 50 /var/log/haagent.log
}

check_client_num() {
    section_deli
    local cmd=""
    if [[ $(is_alamo) -eq 1 ]]; then
        cmd="alamo"
    else
        cmd="gluster"
    fi

    local server_name=""
    local count=0
    local tmpfile=""
    for vol in $(${cmd} volume list); do
        echo "Volume ${vol}'s NFS clients info:"
        tmpfile=$(mktemp)
        ${cmd} volume status "${vol}" nfs clients >"${tmpfile}"
        cat "${tmpfile}"
        while read -r line; do
            IFS=":" read -ra segs <<<"${line}"
            if [[ ${#segs[@]} -lt 2 ]]; then
                continue
            fi

            if [[ ${segs[0]} == "NFS Server " ]]; then
                if [[ -n ${server_name} ]]; then
                    echo "  NFS Server ${server_name} have ${count} clients"
                    server_name=""
                    count=0
                fi
                server_name="${segs[1]}"
            elif [[ ${segs[0]} == "Clients connected " ]]; then
                count="${segs[1]}"
            fi

        done <"${tmpfile}"
        if [[ -n ${server_name} ]]; then
            echo "  NFS Server ${server_name} have ${count} clients"
            server_name=""
            count=0
        fi
        echo ""
    done
}

check_global() {
    check_is_ok check_etcd "ETCD"

    check_ipzone
}

check() {
    RKEY=$(get_rkey)

    check_is_ok check_ntp "NTP"
    check_is_ok check_zpool "POOL"
    check_is_ok check_ctdb_status "CTDB"
    check_is_ok check_disk_status "DISK"

    check_hardware
    check_memory
    check_cpu
    check_log_capacity
    check_load_avg
    check_high_memory_process
    check_disk_count
    check_disk_glitch
    check_pool_capacity
    check_metadata
    check_smbd_count
}

main() {
    if [[ $# != 3 || ($# == 1 && ($1 == "-h" || $1 == "--help")) ]]; then
        echo "$0 <node_prefix> <start_node_index> <count>"
        exit 1
    fi

    local node_prefix=${1}
    local start_index=$2
    local count=$3
    local cur_time=""
    local tmpfile=""
    cur_time=$(date +%Y%m%d%H%M)

    INFO_LOG_FILE=${INFO_LOG_FILE}${cur_time}
    echo $INFO_LOG_FILE

    {
        check_global
        insert_deli

        tmpfile=$(mktemp)
        for i in $(seq "${start_index}" "$((start_index + count - 1))"); do
            {
                node="${node_prefix}${i}"
                echo "${node}'s report:"
                insert_deli
                ssh "${node_prefix}${i}" "$(typeset -f); check" &
                echo ""
            } >"${tmpfile}.${i}" 2>"${tmpfile}.${i}.err"
            pids[${i}]=$!
        done

        for pid in "${pids[@]}"; do
            wait ${pid}
        done
        for i in $(seq "${start_index}" "$((start_index + count - 1))"); do
            cat "${tmpfile}.${i}"
            cat "${tmpfile}.${i}.err" 2>&1
            echo -n "" >"${tmpfile}.${i}"
            echo -n "" >"${tmpfile}.${i}.err"
        done
    } >"${INFO_LOG_FILE}"
}

main "$@"