#!/bin/bash

###### ZPool & SMART status report with FreeNAS config backup
### Original script by joeschmuck, modified by Bidelu0hm, then by melp (me)

### At a minimum, enter email address in user-definable parameter section. Feel free to edit other user parameters as needed.
### If you find any errors, feel free to contact me on the FreeNAS forums (username melp) or email me at jason at jro dot io.

### Version: v1.5
### Changelog:
# v1.5
#   - Added Frag%, Size, Allocated, Free for ZPool status report summary.
#   - Added Disk Size, RPM, Model to the Smart Report
#   - Added if statment so that if "Model Family" is not present script will use "Device Model" 
#       for brand in the SMART Satus report details.
#   - Added Glabel Status Report
#   - Removed Power-On time labels and added ":" as a separator.
#   - Added Power-On format to the Power-On time Header.
#   - Changed Backup deafult to false.
# v1.4
#   - in statusOutput changed grep to scrub: instead of scrub
#   - added elif for resilvered/resilver in progress and scrub in progress with (hopefully) som useful info fields
#   - changed the email subject to include hostname and date & time
# v1.3:
#   - Added scrub duration column
#   - Fixed for FreeNAS 11.1 (thanks reven!)
#   - Fixed fields parsed out of zpool status
#   - Buffered zpool status to reduce calls to script
# v1.2:
#   - Added switch for power-on time format
#   - Slimmed down table columns
#   - Fixed some shellcheck errors & other misc stuff
#   - Added .tar.gz to backup file attached to email
#   - (Still coming) Better SSD SMART support
# v1.1:
#   - Config backup now attached to report email
#   - Added option to turn off config backup
#   - Added option to save backup configs in a specified directory
#   - Power-on hours in SMART summary table now listed as YY-MM-DD-HH
#   - Changed filename of config backup to exclude timestamp (just uses datestamp now)
#   - Config backup and checksum files now zipped (was just .tar before; now .tar.gz)
#   - Fixed degrees symbol in SMART table (rendered weird for a lot of people); replaced with a *
#   - Added switch to enable or disable SSDs in SMART table (SSD reporting still needs work)
#   - Added most recent Extended & Short SMART tests in drive details section (only listed one before, whichever was more recent)
#   - Reformatted user-definable parameters section
#   - Added more general comments to code
# v1.0:
#   - Initial release

### TODO:
# - Fix SSD SMART reporting
# - Add support for conveyance test


###### User-definable Parameters
### Email Address
email="email@address.com"

### Global table colors
okColor="#c9ffcc"       # Hex code for color to use in SMART Status column if drives pass (default is light green, #c9ffcc)
warnColor="#ffd6d6"     # Hex code for WARN color (default is light red, #ffd6d6)
critColor="#ff0000"     # Hex code for CRITICAL color (default is bright red, #ff0000)
altColor="#f4f4f4"      # Table background alternates row colors between white and this color (default is light gray, #f4f4f4)

### zpool status summary table settings
usedWarn=90             # Pool used percentage for CRITICAL color to be used
scrubAgeWarn=30         # Maximum age (in days) of last pool scrub before CRITICAL color will be used

### SMART status summary table settings
includeSSD="false"      # [NOTE: Currently this is pretty much useless] Change to "true" to include SSDs in SMART status summary table; "false" to disable
tempWarn=40             # Drive temp (in C) at which WARNING color will be used
tempCrit=45             # Drive temp (in C) at which CRITICAL color will be used
sectorsCrit=10          # Number of sectors per drive with errors before CRITICAL color will be used
testAgeWarn=5           # Maximum age (in days) of last SMART test before CRITICAL color will be used
powerTimeFormat="ymdh"  # Format for power-on hours string, valid options are "ymdh", "ymd", "ym", or "y" (year month day hour)

### FreeNAS config backup settings
configBackup="false"     # Change to "false" to skip config backup (which renders next two options meaningless); "true" to keep config backups enabled
saveBackup="true"       # Change to "false" to delete FreeNAS config backup after mail is sent; "true" to keep it in dir below
backupLocation="/path/to/config/backup"   # Directory in which to save FreeNAS config backups


###### Auto-generated Parameters
host=$(hostname -s)
logfile="/tmp/smart_report.tmp"
subject="[${host}] Status Report and Configuration Backup $(date "+%Y-%m-%d %H:%M")"
boundary="gc0p4Jq0M2Yt08jU534c0p"
if [ "$includeSSD" == "true" ]; then
    drives=$(for drive in $(sysctl -n kern.disks); do
        if [ "$(smartctl -i /dev/"${drive}" | grep "SMART support is: Enabled")" ]; then
            printf "%s " "${drive}"
        fi
    done | awk '{for (i=NF; i!=0 ; i--) print $i }')
else
    drives=$(for drive in $(sysctl -n kern.disks); do
        if [ "$(smartctl -i /dev/"${drive}" | grep "SMART support is: Enabled")" ] && ! [ "$(smartctl -i /dev/"${drive}" | grep "Solid State Device")" ]; then
            printf "%s " "${drive}"
        fi
    done | awk '{for (i=NF; i!=0 ; i--) print $i }')
fi
pools=$(zpool list -H -o name)


###### Email pre-formatting
### Set email headers
(
    echo "From: ${email}"
    echo "To: ${email}"
    echo "Subject: ${subject}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=${boundary}"
) > "$logfile"


###### Config backup (if enabled)
if [ "$configBackup" == "true" ]; then
    # Set up file names, etc for later
    tarfile="/tmp/config_backup.tar.gz"
    filename="$(date "+FreeNAS_Config_%Y-%m-%d")"
    ### Test config integrity
    if ! [ "$(sqlite3 /data/freenas-v1.db "pragma integrity_check;")" == "ok" ]; then
        # Config integrity check failed, set MIME content type to html and print warning
        (
            echo "--${boundary}"
            echo "Content-Type: text/html"
            echo "<b>Automatic backup of FreeNAS configuration has failed! The configuration file is corrupted!</b>"
            echo "<b>You should correct this problem as soon as possible!</b>"
            echo "<br>"
        ) >> "$logfile"
    else
        # Config integrity check passed; copy config db, generate checksums, make .tar.gz archive
        cp /data/freenas-v1.db "/tmp/${filename}.db"
        md5 "/tmp/${filename}.db" > /tmp/config_backup.md5
        sha256 "/tmp/${filename}.db" > /tmp/config_backup.sha256
        (
            cd "/tmp/" || exit;
            tar -czf "${tarfile}" "./${filename}.db" ./config_backup.md5 ./config_backup.sha256;
        )
        (
            # Write MIME section header for file attachment (encoded with base64)
            echo "--${boundary}"
            echo "Content-Type: application/tar+gzip"
            echo "Content-Transfer-Encoding: base64"
            echo "Content-Disposition: attachment; filename=${filename}.tar.gz"
            base64 "$tarfile"
            # Write MIME section header for html content to come below
            echo "--${boundary}"
            echo "Content-Type: text/html"
        ) >> "$logfile"
        # If logfile saving is enabled, copy .tar.gz file to specified location before it (and everything else) is removed below
        if [ "$saveBackup" == "true" ]; then
            cp "${tarfile}" "${backupLocation}/${filename}.tar.gz"
        fi
        rm "/tmp/${filename}.db"
        rm /tmp/config_backup.md5
        rm /tmp/config_backup.sha256
        rm "${tarfile}"
    fi
else
    # Config backup enabled; set up for html-type content
    (
        echo "--${boundary}"
        echo "Content-Type: text/html"
    ) >> "$logfile"
fi


###### Report Summary Section (html tables)
### zpool status summary table
(
    # Write HTML table headers to log file; HTML in an email requires 100% in-line styling (no CSS or <style> section), hence the massive tags
    echo "<br><br>"
    echo "<table style=\"border: 1px solid black; border-collapse: collapse;\">"
    echo "<tr><th colspan=\"10\" style=\"text-align:center; font-size:20px; height:40px; font-family:courier;\">ZPool Status Report Summary</th></tr>"
    echo "<tr>"
    echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Pool<br>Name</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Status</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Size</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Allocated</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Free</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Frag %</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Used %</th>"    
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Read<br>Errors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Write<br>Errors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Cksum<br>Errors</th>"
    echo "  <th style=\"text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Scrub<br>Repaired<br>Bytes</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Scrub<br>Errors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last<br>Scrub<br>Age</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last<br>Scrub<br>Time</th>"
    echo "</tr>"
) >> "$logfile"
poolNum=0
for pool in $pools; do
    # zpool health summary
    status="$(zpool list -H -o health "$pool")"
    # zpool fragment summary
    frag="$(zpool list -H -p -o frag "$pool" | tr -d %% | awk '{print $0 + 0}')"

    size="$(zpool list -H -o size "$pool")"

    allocated="$(zpool list -H -o allocated "$pool")"

    free="$(zpool list -H -o free "$pool")"

    # Total all read, write, and checksum errors per pool
    errors="$(zpool status "$pool" | grep -E "(ONLINE|DEGRADED|FAULTED|UNAVAIL|REMOVED)[ \\t]+[0-9]+")"
    readErrors=0
    for err in $(echo "$errors" | awk '{print $3}'); do
        if echo "$err" | grep -E -q "[^0-9]+"; then
            readErrors=1000
            break
        fi
        readErrors=$((readErrors + err))
    done
    writeErrors=0
    for err in $(echo "$errors" | awk '{print $4}'); do
        if echo "$err" | grep -E -q "[^0-9]+"; then
            writeErrors=1000
            break
        fi
        writeErrors=$((writeErrors + err))
    done
    cksumErrors=0
    for err in $(echo "$errors" | awk '{print $5}'); do
        if echo "$err" | grep -E -q "[^0-9]+"; then
            cksumErrors=1000
            break
        fi
        cksumErrors=$((cksumErrors + err))
    done
    # Not sure why this changes values larger than 1000 to ">1K", but I guess it works, so I'm leaving it
    if [ "$readErrors" -gt 999 ]; then readErrors=">1K"; fi
    if [ "$writeErrors" -gt 999 ]; then writeErrors=">1K"; fi
    if [ "$cksumErrors" -gt 999 ]; then cksumErrors=">1K"; fi
    # Get used capacity percentage of the zpool
    used="$(zpool list -H -p -o capacity "$pool")"
    # Gather info from most recent scrub; values set to "N/A" initially and overwritten when (and if) it gathers scrub info
    scrubRepBytes="N/A"
    scrubErrors="N/A"
    scrubAge="N/A"
    scrubTime="N/A"
    resilver=""

    statusOutput="$(zpool status "$pool")"
    # normal status i.e. scrub
    if [ "$(echo "$statusOutput" | grep "scan:" | awk '{print $2" "$3}')" = "scrub repaired" ]; then
        scrubRepBytes="$(echo "$statusOutput" | grep "scan:" | awk '{print $4}')"
        scrubErrors="$(echo "$statusOutput" | grep "scan:" | awk '{print $10}')"
        # Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
        scrubDate="$(echo "$statusOutput" | grep "scan:" | awk '{print $17"-"$14"-"$15"_"$16}')"
        scrubTS="$(date -j -f "%Y-%b-%e_%H:%M:%S" "$scrubDate" "+%s")"
        currentTS="$(date "+%s")"
        scrubAge=$((((currentTS - scrubTS) + 43200) / 86400))
        scrubTime="$(echo "$statusOutput" | grep "scan:" | awk '{print $8}')"

    # if status is resilvered
    elif [ "$(echo "$statusOutput" | grep "scan:" | awk '{print $2}')" = "resilvered" ]; then
            resilver="<BR>Resilvered"
            scrubRepBytes="$(echo "$statusOutput" | grep "scan:" | awk '{print $3}')"
            scrubErrors="$(echo "$statusOutput" | grep "scan:" | awk '{print $9}')"
            # Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
            scrubDate="$(echo "$statusOutput" | grep "scan:" | awk '{print $16"-"$13"-"$14"_"$15}')"
            scrubTS="$(date -j -f "%Y-%b-%e_%H:%M:%S" "$scrubDate" "+%s")"
            currentTS="$(date "+%s")"
            scrubAge=$((((currentTS - scrubTS) + 43200) / 86400))
            scrubTime="$(echo "$statusOutput" | grep "scan:" | awk '{print $7}')"

    # Check if resilver is in progress
    elif [ "$(echo "$statusOutput"| grep "scan:" | awk '{print $2}')" = "resilver" ]; then
        scrubRepBytes="Resilver In Progress"
        scrubAge="$(echo "$statusOutput" | grep "resilvered," | awk '{print $3" done"}')"
        if [ "$(echo "$statusOutput" | grep "resilvered," | awk '{print $5}')" = "0" ]; then
            scrubTime="$(echo "$statusOutput" | grep "resilvered," | awk '{print $7"<br>to go"}')"
        else
            scrubTime="$(echo "$statusOutput" | grep "resilvered," | awk '{print $5" "$6" "$7"<br>to go"}')"
        fi

    # Check if scrub is in progress
    elif [ "$(echo "$statusOutput"| grep "scan:" | awk '{print $4}')" = "progress" ]; then
        scrubRepBytes="Scrub In Progress"
        scrubErrors="$(echo "$statusOutput" | grep "repaired," | awk '{print $1" repaired"}')"
        scrubAge="$(echo "$statusOutput" | grep "repaired," | awk '{print $3" done"}')"
        if [ "$(echo "$statusOutput" | grep "repaired," | awk '{print $5}')" = "0" ]; then
            scrubTime="$(echo "$statusOutput" | grep "repaired," | awk '{print $7"<br>to go"}')"
        else
            scrubTime="$(echo "$statusOutput" | grep "repaired," | awk '{print $5" "$6" "$7"<br>to go"}')"
        fi
    fi

   # Set row's background color; alternates between white and $altColor (light gray)
    if [ $((poolNum % 2)) == 1 ]; then bgColor="#ffffff"; else bgColor="$altColor"; fi
    poolNum=$((poolNum + 1))
    # Set up conditions for warning or critical colors to be used in place of standard background colors
    if [ "$status" != "ONLINE" ]; then statusColor="$warnColor"; else statusColor="$bgColor"; fi
    status+="$resilver"
    if [ "$readErrors" != "0" ]; then readErrorsColor="$warnColor"; else readErrorsColor="$bgColor"; fi
    if [ "$writeErrors" != "0" ]; then writeErrorsColor="$warnColor"; else writeErrorsColor="$bgColor"; fi
    if [ "$cksumErrors" != "0" ]; then cksumErrorsColor="$warnColor"; else cksumErrorsColor="$bgColor"; fi
    if [ "$used" -gt "$usedWarn" ]; then usedColor="$warnColor"; else usedColor="$bgColor"; fi
    if [ "$scrubRepBytes" != "N/A" ] && [ "$scrubRepBytes" != "0" ]; then scrubRepBytesColor="$warnColor"; else scrubRepBytesColor="$bgColor"; fi
    if [ "$scrubErrors" != "N/A" ] && [ "$scrubErrors" != "0" ]; then scrubErrorsColor="$warnColor"; else scrubErrorsColor="$bgColor"; fi
    if [ "$(echo "$scrubAge" | awk '{print int($1)}')" -gt "$scrubAgeWarn" ]; then scrubAgeColor="$warnColor"; else scrubAgeColor="$bgColor"; fi
    (
        # Use the information gathered above to write the date to the current table row
        printf "<tr style=\"background-color:%s;\">
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s%%</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s%%</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
            <td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
        </tr>\\n" "$bgColor" "$pool" "$statusColor" "$status" "$size" "$allocated" "$free" "$frag" "$usedColor" "$used" "$readErrorsColor" "$readErrors" "$writeErrorsColor" "$writeErrors" "$cksumErrorsColor" \
        "$cksumErrors" "$scrubRepBytesColor" "$scrubRepBytes" "$scrubErrorsColor" "$scrubErrors" "$scrubAgeColor" "$scrubAge" "$scrubTime"
    ) >> "$logfile"
done
# End of zpool status table
echo "</table>" >> "$logfile"

### SMART status summary table
(
    # Write HTML table headers to log file
    echo "<br><br>"
    echo "<table style=\"border: 1px solid black; border-collapse: collapse;\">"
    echo "<tr><th colspan=\"15\" style=\"text-align:center; font-size:20px; height:40px; font-family:courier;\">SMART Status Report Summary</th></tr>"
    echo "<tr>"
    echo "  <th style=\"text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Device</th>"
    echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Model</th>"
    echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Serial<br>Number</th>"
    echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">RPM</th>"
    echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Capacity</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">SMART<br>Status</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Temp</th>"
    echo "  <th style=\"text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Power-On<br>Time<br>($powerTimeFormat)</th>"
    echo "  <th style=\"text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Start/Stop<br>Count</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Spin<br>Retry<br>Count</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Realloc'd<br>Sectors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Realloc<br>Events</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Current<br>Pending<br>Sectors</th>"
    echo "  <th style=\"text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Offline<br>Uncorrectable<br>Sectors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">UltraDMA<br>CRC<br>Errors</th>"
    echo "  <th style=\"text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Seek<br>Error<br>Health</th>"
    echo "  <th style=\"text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last Test<br>Age (days)</th>"
    echo "  <th style=\"text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last Test<br>Type</th></tr>"    
    echo "</tr>"
) >> "$logfile"
for drive in $drives; do
    (
        # For each drive detected, run "smartctl -A -i" and parse its output. This whole section is a single, long statement, so I'll make all comments here.
        # Start by passing awk variables (all the -v's) used in other parts of the script. Other variables are calculated in-line with other smartctl calls.
        # Next, pull values out of the original "smartctl -A -i" statement by searching for the text between the //'s.
        # After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
        # After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
        # Finally, print the HTML code for the current row of the table with all the gathered data.
        smartctl -A -i /dev/"$drive" | \
        awk -v device="$drive" -v tempWarn="$tempWarn" -v tempCrit="$tempCrit" -v sectorsCrit="$sectorsCrit" -v testAgeWarn="$testAgeWarn" \
        -v okColor="$okColor" -v warnColor="$warnColor" -v critColor="$critColor" -v altColor="$altColor" -v powerTimeFormat="$powerTimeFormat" \
        -v lastTestHours="$(smartctl -l selftest /dev/"$drive" | grep "# 1" | awk '{print $9}')" \
        -v lastTestType="$(smartctl -l selftest /dev/"$drive" | grep "# 1" | awk '{print $3}')" \
        -v smartStatus="$(smartctl -H /dev/"$drive" | grep "SMART overall-health" | awk '{print $6}')" ' \
        /Device Model:/{$1="";$2=""; model=$0} \
        /Serial Number:/{serial=$3} \
        /User Capacity:/{capacity=$5 $6} \
        /Rotation Rate:/{rpm=$3} \
        $1 ~ /^194$/{temp=($10 + 0)} \
        $1 ~ /^9$/{onHours=$10} \
        $1 ~ /^4$/{startStop=$10} \
        $1 ~ /^10$/{spinRetry=$10} \
        $1 ~ /^5$/{reAlloc=$10} \
        $1 ~ /^196$/{reAllocEvent=$10} \
        $1 ~ /^197$/{pending=$10} \
        $1 ~ /^198$/{offlineUnc=$10} \
        $1 ~ /^199$/{crcErrors=$10} \
        $1 ~ /^7$/{seekErrorHealth=$4} \
        END {
            testAge=int((onHours - lastTestHours) / 24);
            yrs=int(onHours / 8760);
            mos=int((onHours % 8760) / 730);
            dys=int(((onHours % 8760) % 730) / 24);
            hrs=((onHours % 8760) % 730) % 24;
            if (powerTimeFormat == "ymdh") onTime=yrs ":" mos ":" dys ":" hrs;
            else if (powerTimeFormat == "ymd") onTime=yrs ":" mos ":" dys;
            else if (powerTimeFormat == "ym") onTime=yrs ":" mos;
            else if (powerTimeFormat == "y") onTime=yrs;
            else onTime=yrs ":" mos ":" dys ":" hrs;
            if ((substr(device,3) + 0) % 2 == 1) bgColor = "#ffffff"; else bgColor = altColor;
            if (smartStatus != "PASSED") smartStatusColor = critColor; else smartStatusColor = okColor;
            if (temp >= tempCrit) tempColor = critColor; else if (temp >= tempWarn) tempColor = warnColor; else tempColor = bgColor;
            if (spinRetry != "0") spinRetryColor = warnColor; else spinRetryColor = bgColor;
            if ((reAlloc + 0) > sectorsCrit) reAllocColor = critColor; else if (reAlloc != 0) reAllocColor = warnColor; else reAllocColor = bgColor;
            if (reAllocEvent != "0") reAllocEventColor = warnColor; else reAllocEventColor = bgColor;
            if ((pending + 0) > sectorsCrit) pendingColor = critColor; else if (pending != 0) pendingColor = warnColor; else pendingColor = bgColor;
            if ((offlineUnc + 0) > sectorsCrit) offlineUncColor = critColor; else if (offlineUnc != 0) offlineUncColor = warnColor; else offlineUncColor = bgColor;
            if (crcErrors != "0") crcErrorsColor = warnColor; else crcErrorsColor = bgColor;
            if ((seekErrorHealth + 0) < 100) seekErrorHealthColor = warnColor; else seekErrorHealthColor = bgColor;
            if (testAge > testAgeWarn) testAgeColor = warnColor; else testAgeColor = bgColor;
            printf "<tr style=\"background-color:%s;\">" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">/dev/%s</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%d*C</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s%%</td>" \
                "<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%d</td>" \
                "<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
            "</tr>\n", bgColor, device, model, serial, rpm, capacity, smartStatusColor, smartStatus, tempColor, temp, onTime, startStop, spinRetryColor, spinRetry, reAllocColor, reAlloc, \
            reAllocEventColor, reAllocEvent, pendingColor, pending, offlineUncColor, offlineUnc, crcErrorsColor, crcErrors, seekErrorHealthColor, seekErrorHealth, \
            testAgeColor, testAge, lastTestType;
        }'
    ) >> "$logfile"
done
# End SMART summary table and summary section
(
    echo "</table>"
    echo "<br><br>"
) >> "$logfile"


###### Detailed Report Section (monospace text)
echo "<pre style=\"font-size:14px\">" >> "$logfile"

### Print Glabel Status
(
    echo "<b>########## Glabel Status ##########</b>"
    glabel status
    echo "<br>"
) >> "$logfile"

### zpool status for each pool
for pool in $pools; do
    (
        # Create a simple header and drop the output of zpool status -v
        echo "<b>########## ZPool status report for ${pool} ##########</b>"
        zpool status -v "$pool"
        echo "<br><br>"
    ) >> "$logfile"
done

### SMART status for each drive
for drive in $drives; do
    # Gather brand and serial number of each drive
    brand="$(smartctl -i /dev/"$drive" | grep "Model Family" | awk '{print $3, $4, $5}')"
    if [ "$brand" == "" ]; then  brand="$(smartctl -i /dev/"$drive" | grep "Device Model" | awk '{print $3, $4, $5}')"; fi
    serial="$(smartctl -i /dev/"$drive" | grep "Serial Number" | awk '{print $3}')"
    (
        # Create a simple header and drop the output of some basic smartctl commands
        echo "<br>"
        echo "<b>########## SMART status report for ${drive} drive (${brand}: ${serial}) ##########</b>"
        smartctl -H -A -l error /dev/"$drive"
        smartctl -l selftest /dev/"$drive" | grep "Extended \\|Num" | cut -c6- | head -2
        smartctl -l selftest /dev/"$drive" | grep "Short \\|Num" | cut -c6- | head -2 | tail -n -1
        echo "<br><br>"
    ) >> "$logfile"
done
# Remove some un-needed junk from the output
sed -i '' -e '/smartctl 6.3/d' "$logfile"
sed -i '' -e '/Copyright/d' "$logfile"
sed -i '' -e '/=== START OF READ/d' "$logfile"
sed -i '' -e '/SMART Attributes Data/d' "$logfile"
sed -i '' -e '/Vendor Specific SMART/d' "$logfile"
sed -i '' -e '/SMART Error Log Version/d' "$logfile"

### End details section, close MIME section
(
    echo "</pre>"
    echo "--${boundary}--"
)  >> "$logfile"

### Send report
sendmail -t -oi < "$logfile"
rm "$logfile"
