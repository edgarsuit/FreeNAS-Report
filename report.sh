#!/bin/bash
# shellcheck disable=SC1004,SC2236

#set -euxo pipefail

###### ZPool, SMART, and UPS Status Report with TrueNAS Config Backup
### Original Script By: joeschmuck
### Modified By: bidelu0hm, melp, fohlsso2, onlinepcwizard, ninpucho, isentropik, dak180
### Last Edited By: dak180

### At a minimum, enter email address and set defaultFile to 0 in the config file.
### Feel free to edit other user parameters as needed.

### Current Version: v1.7.5
### https://github.com/dak180/FreeNAS-Report

### Changelog:
# v1.7.5
#   - Add initial support for SAS drives
# v1.7
#   - Refactor to reduce dependence on awk
#   - Use a separate config file
#   - Add support for conveyance test
# v1.6.5
#   - HTML boundary fix, proper message ids, support for dma mailer
#   - Better support for NVMe and SSD
#   - Support for new smartmon-tools
# v1.6
#   - Actually fixed the broken borders in the tables.
#   - Split the SMART table into two tables, one for SSDs and one for HDDs.
#   - Added several options for SSD reporting.
#   - Modified the SSD table in order to capture relevant (seemingly) SSD data.
#   - Changed 'include SSD' default to true.
#   - Cleaned up minor formatting and error handling issues (tried to have the cell fill with "N/A" instead of non-sensical values).
# v1.5
#   - Added Frag%, Size, Allocated, Free for ZPool status report summary.
#   - Added Disk Size, RPM, Model to the Smart Report
#   - Added if statment so that if "Model Family" is not present script will use "Device Model" for brand in the SMART Satus report details.
#   - Added Glabel Status Report
#   - Removed Power-On time labels and added ":" as a separator.
#   - Added Power-On format to the Power-On time Header.
#   - Changed Backup default to false.
# v1.4
#   - in statusOutput changed grep to scrub: instead of scrub
#   - added elif for resilvered/resilver in progress and scrub in progress with (hopefully) som useful info fields
#   - changed the email subject to include hostname and date & time
# v1.3
#   - Added scrub duration column
#   - Fixed for FreeNAS 11.1 (thanks reven!)
#   - Fixed fields parsed out of zpool status
#   - Buffered zpool status to reduce calls to script
# v1.2
#   - Added switch for power-on time format
#   - Slimmed down table columns
#   - Fixed some shellcheck errors & other misc stuff
#   - Added .tar.gz to backup file attached to email
#   - (Still coming) Better SSD SMART support
# v1.1
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
# v1.0
#   - Initial release


# Functions
function rpConfig () {
	# Write out a default config file
	tee > "${configFile}" <<"EOF"

# Set this to 0 to enable
defaultFile="1"

###### User-definable Parameters
### Email Address
email="email@address.com"

### Global table colors
okColor="#c9ffcc"       # Hex code for color to use in SMART Status column if drives pass (default is light green, #c9ffcc)
warnColor="#ffd6d6"     # Hex code for WARN color (default is light red, #ffd6d6)
critColor="#ff0000"     # Hex code for CRITICAL color (default is bright red, #ff0000)
altColor="#f4f4f4"      # Table background alternates row colors between white and this color (default is light gray, #f4f4f4)

### zpool status summary table settings
usedWarn="90"             # Pool used percentage for CRITICAL color to be used
scrubAgeWarn="30"         # Maximum age (in days) of last pool scrub before CRITICAL color will be used

### SMART status summary table settings
includeSSD="true"       # Change to "true" to include SSDs in SMART status summary table; "false" to disable
lifeRemainWarn="75"       # Life remaining in the SSD at which WARNING color will be used
lifeRemainCrit="50"       # Life remaining in the SSD at which CRITICAL color will be used
totalBWWarn="100"         # Total bytes written (in TB) to the SSD at which WARNING color will be used
totalBWCrit="200"         # Total bytes written (in TB) to the SSD at which CRITICAL color will be used
tempWarn="35"             # Drive temp (in C) at which WARNING color will be used
tempCrit="40"             # Drive temp (in C) at which CRITICAL color will be used
ssdTempWarn="40"          # SSD drive temp (in C) at which WARNING color will be used
ssdTempCrit="45"          # SSD drive temp (in C) at which CRITICAL color will be used
sectorsCrit="10"          # Number of sectors per drive with errors before CRITICAL color will be used
testAgeWarn="5"           # Maximum age (in days) of last SMART test before CRITICAL color will be used
powerTimeFormat="ymdh"  # Format for power-on hours string, valid options are "ymdh", "ymd", "ym", or "y" (year month day hour)

### TrueNAS config backup settings
configBackup="false"     # Change to "false" to skip config backup (which renders next two options meaningless); "true" to keep config backups enabled
emailBackup="false"     # Change to "true" to email TrueNAS config backup
saveBackup="true"       # Change to "false" to delete TrueNAS config backup after mail is sent; "true" to keep it in dir below
backupLocation="/root/backup"    # Directory in which to save TrueNAS config backups

### UPS status summary settings
reportUPS="false"        # Change to "false" to skip reporting the status of the UPS

### General script settings
logfileLocation="/tmp"      # Directory in which to save TrueNAS log file. Can be set to /tmp.
logfileName="logfilename"                  # Log file name
saveLogfile="true"                         # Change to "false" to delete the log file after creation



EOF
	echo "Please edit the config file for your setup" >&2
	exit 0
}

function ConfigBackup () {
    local tarfile
    local fnconfigdest_version
    local fnconfigdest_date
    local filename


    # Set up file names, etc for later
    tarfile="/tmp/config_backup.tar.gz"
    fnconfigdest_version="$(< /etc/version sed -e 's:)::' -e 's:(::' -e 's: :-:' | tr -d '\n')"
    fnconfigdest_date="$(date -r "${runDate}" '+%Y%m%d%H%M%S')"
    filename="${fnconfigdest_date}_${fnconfigdest_version}"

    ### Test config integrity
    if [ ! "$(sqlite3 "/data/freenas-v1.db" "pragma integrity_check;")" = "ok" ]; then

        # Config integrity check failed, set MIME content type to html and print warning
        {
            echo "--${boundary}"
            echo "Content-Transfer-Encoding: 8bit"
            echo -e "Content-Type: text/html; charset=utf-8\n"
            echo "<b>Automatic backup of TrueNAS configuration has failed! The configuration file is corrupted!</b>"
            echo "<b>You should correct this problem as soon as possible!</b>"
            echo "<br>"
        } >> "${logfile}"
    else
        # Config integrity check passed; copy config db, generate checksums, make .tar.gz archive
        sqlite3 "/data/freenas-v1.db" ".backup main /tmp/${filename}.db"
        cp -f "/data/pwenc_secret" "/tmp/"
        md5 "/tmp/${filename}.db" > /tmp/config_backup.md5
        sha256 "/tmp/${filename}.db" > /tmp/config_backup.sha256
        (
            cd "/tmp/" || exit;
            tar -czf "${tarfile}" "./${filename}.db" "./config_backup.md5" "./config_backup.sha256" "./pwenc_secret"
        )
        {
			if [ "${emailBackup}" = "true" ]; then
				# Write MIME section header for file attachment (encoded with base64)
				echo "--${boundary}"
				echo -e "Content-Type: application/tar+gzip\n"
				echo "Content-Transfer-Encoding: base64"
				echo "Content-Disposition: attachment; filename=${filename}.tar.gz"
				base64 "${tarfile}"
			fi

            # Write MIME section header for html content to come below
            echo "--${boundary}"
            echo "Content-Transfer-Encoding: 8bit"
            echo -e "Content-Type: text/html; charset=utf-8\n"
        } >> "${logfile}"

        # If logfile saving is enabled, copy .tar.gz file to specified location before it (and everything else) is removed below
        if [ "${saveBackup}" = "true" ]; then
            cp "${tarfile}" "${backupLocation}/${filename}.tar.gz"
        fi
        rm "/tmp/${filename}.db"
        rm "/tmp/config_backup.md5"
        rm "/tmp/config_backup.sha256"
        rm "${tarfile}"
    fi
}

function ZpoolSummary () {
	local pool
	local status
	local frag
	local size
	local allocated
	local free
	local errors
	local readErrors
	local err
	local writeErrors
	local cksumErrors
	local used
	local scrubRepBytes
	local scrubErrors
	local scrubAge
	local scrubTime
	local resilver
	local statusOutput
	local bgColor
	local statusColor
	local readErrorsColor
	local writeErrorsColor
	local cksumErrorsColor
	local usedColor
	local scrubRepBytesColor
	local scrubErrorsColor
	local scrubAgeColor
	local multiDay
	local altRow


	### zpool status summary table
	{
		# Write HTML table headers to log file; HTML in an email requires 100% in-line styling (no CSS or <style> section), hence the massive tags
		echo '<br><br>'
		echo '<table style="border: 1px solid black; border-collapse: collapse;">'
		echo '<tr><th colspan="14" style="text-align:center; font-size:20px; height:40px; font-family:courier;">ZPool Status Report Summary</th></tr>'
		echo '<tr>'
		echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Pool<br>Name</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Status</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Size</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Allocated</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Free</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Frag %</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Used %</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Read<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Write<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Cksum<br>Errors</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Scrub<br>Repaired<br>Bytes</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Scrub<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last<br>Scrub<br>Age (days)</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last<br>Scrub<br>Duration</th>'
		echo '</tr>'
	} >> "${logfile}"


	altRow="false"
	for pool in "${pools[@]}"; do

		# zpool health summary
		status="$(zpool list -H -o health "${pool}")"

		# zpool fragment summary
		frag="$(zpool list -H -p -o frag "${pool}" | tr -d %% | awk '{print $0 + 0}')"
		size="$(zpool list -H -o size "${pool}")"
		allocated="$(zpool list -H -o allocated "${pool}")"
		free="$(zpool list -H -o free "${pool}")"

		# Total all read, write, and checksum errors per pool
		errors="$(zpool status "${pool}" | grep -E "(ONLINE|DEGRADED|FAULTED|UNAVAIL|REMOVED)[ \\t]+[0-9]+")"
		readErrors="0"
		for err in $(echo "${errors}" | awk '{print $3}'); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				readErrors="1000"
				break
			fi
			readErrors="$((readErrors + err))"
		done
		writeErrors="0"
		for err in $(echo "${err}ors" | awk '{print $4}'); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				writeErrors="1000"
				break
			fi
			writeErrors="$((writeErrors + err))"
		done
		cksumErrors="0"
		for err in $(echo "${err}ors" | awk '{print $5}'); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				cksumErrors="1000"
				break
			fi
			cksumErrors="$((cksumErrors + err))"
		done
		# Not sure why this changes values larger than 1000 to ">1K", but I guess it works, so I'm leaving it
		if [ "${readErrors}" -gt 999 ]; then readErrors=">1K"; fi
		if [ "${writeErrors}" -gt 999 ]; then writeErrors=">1K"; fi
		if [ "${cksumErrors}" -gt 999 ]; then cksumErrors=">1K"; fi

		# Get used capacity percentage of the zpool
		used="$(zpool list -H -p -o capacity "${pool}")"

		# Gather info from most recent scrub; values set to "N/A" initially and overwritten when (and if) it gathers scrub info
		scrubRepBytes="N/A"
		scrubErrors="N/A"
		scrubAge="N/A"
		scrubTime="N/A"
		resilver=""

		statusOutput="$(zpool status "${pool}")"
		# normal status i.e. scrub
		if [ "$(echo "${statusOutput}" | grep "scan:" | awk '{print $2" "$3}')" = "scrub repaired" ]; then
			multiDay="$(echo "${statusOutput}" | grep "scan" | grep -c "days")"
			scrubRepBytes="$(echo "${statusOutput}" | grep "scan:" | awk '{gsub(/B/,"",$4); print $4}')"
			if [ "${multiDay}" -ge 1 ] ; then
				scrubErrors="$(echo "${statusOutput}" | grep "scan:" | awk '{print $10}')"
			else
				scrubErrors="$(echo "${statusOutput}" | grep "scan:" | awk '{print $8}')"
			fi

			# Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
			if [ "${multiDay}" -ge 1 ] ; then
				scrubDate="$(echo "${statusOutput}" | grep "scan:" | awk '{print $17"-"$14"-"$15"_"$16}')"
			else
				scrubDate="$(echo "${statusOutput}" | grep "scan:" | awk '{print $15"-"$12"-"$13"_"$14}')"
			fi
			scrubTS="$(date -j -f '%Y-%b-%e_%H:%M:%S' "${scrubDate}" '+%s')"
			currentTS="${runDate}"
			scrubAge="$((((currentTS - scrubTS) + 43200) / 86400))"
			if [ "${multiDay}" -ge 1 ] ; then
				scrubTime="$(echo "${statusOutput}" | grep "scan" | awk '{print $6" "$7" "$8}')"
			else
				scrubTime="$(echo "${statusOutput}" | grep "scan" | awk '{print $6}')"
			fi

		# if status is resilvered
		elif [ "$(echo "${statusOutput}" | grep "scan:" | awk '{print $2}')" = "resilvered" ]; then
			resilver="<BR>Resilvered"
			scrubRepBytes="$(echo "${statusOutput}" | grep "scan:" | awk '{print $3}')"
			scrubErrors="$(echo "${statusOutput}" | grep "scan:" | awk '{print $7}')"

			# Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
			scrubDate="$(echo "${statusOutput}" | grep "scan:" | awk '{print $14"-"$11"-"$12"_"$13}')"
			scrubTS="$(date -j -f '%Y-%b-%e_%H:%M:%S' "${scrubDate}" '+%s')"
			currentTS="${runDate}"
			scrubAge="$((((currentTS - scrubTS) + 43200) / 86400))"
			scrubTime="$(echo "${statusOutput}" | grep "scan:" | awk '{print $5}')"

		# Check if resilver is in progress
		elif [ "$(echo "${statusOutput}"| grep "scan:" | awk '{print $2}')" = "resilver" ]; then
			scrubRepBytes="Resilver In Progress"
			scrubAge="$(echo "${statusOutput}" | grep "resilvered," | awk '{print $3" done"}')"
			scrubTime="$(echo "${statusOutput}" | grep "resilvered," | awk '{print $5"<br>to go"}')"

		# Check if scrub is in progress
		elif [ "$(echo "${statusOutput}"| grep "scan:" | awk '{print $4}')" = "progress" ]; then
			scrubRepBytes="Scrub In Progress"
			scrubErrors="$(echo "${statusOutput}" | grep "repaired," | awk '{print $1" repaired"}')"
			scrubAge="$(echo "${statusOutput}" | grep "repaired," | awk '{print $3" done"}')"
			if [ "$(echo "${statusOutput}" | grep "repaired," | awk '{print $5}')" = "0" ]; then
				scrubTime="$(echo "${statusOutput}" | grep "repaired," | awk '{print $7"<br>to go"}')"
			else
				scrubTime="$(echo "${statusOutput}" | grep "repaired," | awk '{print $5" "$6" "$7"<br>to go"}')"
			fi
		fi

		# Set the row background color
		if [ "${altRow}" = "false" ]; then
			local bgColor="#ffffff"
			altRow="true"
		else
			local bgColor="${altColor}"
			altRow="false"
		fi

		# Set up conditions for warning or critical colors to be used in place of standard background colors
		if [ ! "${status}" = "ONLINE" ]; then
			statusColor="${warnColor}"
		else
			statusColor="${bgColor}"
		fi
		status+="${resilver}"

		if [ ! "${readErrors}" = "0" ]; then
			readErrorsColor="${warnColor}"
		else
			readErrorsColor="${bgColor}"
		fi

		if [ ! "${writeErrors}" = "0" ]; then
			writeErrorsColor="${warnColor}"
		else
			writeErrorsColor="${bgColor}"
		fi

		if [ ! "${cksumErrors}" = "0" ]; then
			cksumErrorsColor="${warnColor}"
		else
			cksumErrorsColor="${bgColor}"
		fi

		if [ "${used}" -gt "${usedWarn}" ]; then
			usedColor="${warnColor}"
		else
			usedColor="${bgColor}"
		fi

		if [ ! "${scrubRepBytes}" = "N/A" ] && [ ! "${scrubRepBytes}" = "0" ] && [ ! "${scrubRepBytes}" = "0B" ]; then
			scrubRepBytesColor="${warnColor}"
		else
			scrubRepBytesColor="${bgColor}"
		fi

		if [ ! "${scrubErrors}" = "N/A" ] && [ ! "${scrubErrors}" = "0" ]; then
			scrubErrorsColor="${warnColor}"
		else
			scrubErrorsColor="${bgColor}"
		fi

		if [ "$(echo "$scrubAge" | awk '{print int($1)}')" -gt "${scrubAgeWarn}" ]; then
			scrubAgeColor="${warnColor}"
		else
			scrubAgeColor="${bgColor}"
		fi

		{
			# Use the information gathered above to write the date to the current table row
			echo '<tr style="background-color:'"${bgColor}"'">'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${pool}"'</td>'
			echo '<td style="text-align:center; background-color:'"${statusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${status}"'</td>'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${size}"'</td>'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${allocated}"'</td>'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${free}"'</td>'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${frag}"'%</td>'
			echo '<td style="text-align:center; background-color:'"${usedColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${used}"'%</td>'
			echo '<td style="text-align:center; background-color:'"${readErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${readErrors}"'</td>'
			echo '<td style="text-align:center; background-color:'"${writeErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${writeErrors}"'</td>'
			echo '<td style="text-align:center; background-color:'"${cksumErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${cksumErrors}"'</td>'
			echo '<td style="text-align:center; background-color:'"${scrubRepBytesColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${scrubRepBytes}"'</td>'
			echo '<td style="text-align:center; background-color:'"${scrubErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${scrubErrors}"'</td>'
			echo '<td style="text-align:center; background-color:'"${scrubAgeColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${scrubAge}"'</td>'
			echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${scrubTime}"'</td>'
			echo '</tr>'
		} >> "${logfile}"
	done

	# End of zpool status table
	echo '</table>' >> "${logfile}"
}

# shellcheck disable=SC2155
function NVMeSummary () {

	###### NVMe SMART status summary table
	{
		# Write HTML table headers to log file
		echo '<br><br>'
		echo '<table style="border: 1px solid black; border-collapse: collapse;">'
		echo '<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">NVMe SMART Status Report Summary</th></tr>'
		echo '<tr>'

		echo '  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>' # Device

		echo '  <th style="text-align:center; width:140px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>' # Model

		echo '  <th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>' # Serial Number

		echo '  <th style="text-align:center; width:90px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>' # Capacity

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>' # SMART Status

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>' # Temp

		echo '  <th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>('"$powerTimeFormat"')</th>' # Power-On Time

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power<br>Cycle<br>Count</th>' # Power Cycle Count

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Integrity<br>Errors</th>' # Integrity Errors

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Error<br>Log<br>Entries</th>' # Error Log Entries

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Critical<br>Warning</th>' # Critical Warning

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Wear<br>Leveling<br>Count</th>' # Wear Leveling Count

		echo '  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Total<br>Bytes<br>Written</th>' # Total Bytes Written

		echo '  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Bytes Written<br>(per Day)</th>' # Bytes Written (per Day)

		echo '  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>' # Last Test Age (days)

		echo '  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>' # Last Test Type

		echo '</tr>'
	} >> "${logfile}"


	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		if echo "${drive}" | grep -q "nvme"; then
			# For each drive detected, run "smartctl -AHij" and parse its output.
			# Start by parsing variables used in other parts of the script.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			# Get drive attributes
			local nvmeSmarOut="$(smartctl -AHij "/dev/${drive}")"

			local model="$(echo "${nvmeSmarOut}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${nvmeSmarOut}" | jq -Mre '.serial_number | values')"
			local temp="$(echo "${nvmeSmarOut}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${nvmeSmarOut}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${nvmeSmarOut}" | jq -Mre '.power_cycle_count | values')"
			local sectorSize="$(echo "${nvmeSmarOut}" | jq -Mre '.logical_block_size | values')"

			local mediaErrors="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.media_errors | values')"
			local errorsLogs="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.num_err_log_entries | values')"
			local critWarning="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.critical_warning | values')"
			local wearLeveling="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.available_spare | values')"
			local totalLBA="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.data_units_written | values')"

			local capacity="$(smartctl -i "/dev/${drive}" | grep '^Namespace 1 Size' | tr -s ' ' | cut -d ' ' -sf '5,6')" # FixMe: have not yet figured out how to best calculate this from json values

			if [ "$(echo "${nvmeSmarOut}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			# Get more useful times from hours
			local testAge="$(bc <<< "(${onHours} - (${onHours} - 2) ) / 24")" # ${lastTestHours}
			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize smart status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize temp
			if [ "${temp}" -ge "${ssdTempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp}" -ge "${ssdTempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize log errors
			if [ "${errorsLogs:=0}" -gt "${sectorsCrit}" ]; then
				local errorsLogsColor="${critColor}"
			elif [ ! "${errorsLogs}" = "0" ]; then
				local errorsLogsColor="${warnColor}"
			else
				local errorsLogsColor="${bgColor}"
			fi

			# Colorize warnings
			if [ "${critWarning:=0}" -gt "${sectorsCrit}" ]; then
				local critWarningColor="${critColor}"
			elif [ ! "${critWarning}" = "0" ]; then
				local critWarningColor="${warnColor}"
			else
				local critWarningColor="${bgColor}"
			fi

			# Colorize Media Errors
			if [ ! "${mediaErrors}" = "0" ]; then
				local mediaErrorsColor="${warnColor}"
			else
				local mediaErrorsColor="${bgColor}"
			fi

			# Colorize Wear Leveling
			if [ "${wearLeveling}" -le "${lifeRemainCrit}" ]; then
				local wearLevelingColor="${critColor}"
			elif [ "${wearLeveling}" -le "${lifeRemainWarn}" ]; then
				local wearLevelingColor="${warnColor}"
			else
				local wearLevelingColor="${bgColor}"
			fi

			# Colorize & derive write stats
			local totalBW="$(bc <<< "scale=1; (${totalLBA} * ${sectorSize}) / (1000^3)" | sed -e 's:^\.:0.:')"
			if (( $(bc -l <<< "${totalBW} > ${totalBWCrit}") )); then
				local totalBWColor="${critColor}"
			elif (( $(bc -l <<< "${totalBW} > ${totalBWWarn}") )); then
				local totalBWColor="${warnColor}"
			else
				local totalBWColor="${bgColor}"
			fi
			if [ "${totalBW}" = "0.0" ]; then
				totalBW="N/A"
			else
				totalBW="${totalBW}TB"
			fi
			# Try to not divide by zero
			if [ ! "0" = "$(bc <<< "scale=1; ${onHours} / 24")" ]; then
				local bwPerDay="$(bc <<< "scale=1; (((${totalLBA} * ${sectorSize}) / (1000^3)) * 1000) / (${onHours} / 24)" | sed -e 's:^\.:0.:')"
				if [ "${bwPerDay}" = "0.0" ]; then
					bwPerDay="N/A"
				else
					bwPerDay="${bwPerDay}GB"
				fi
			else
				local bwPerDay="N/A"
			fi

			# Colorize test age
			if [ "${testAge}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


			{
				# Output the row
				echo '<tr style="background-color:'"${bgColor}"';">'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"/dev/${drive}"'</td> <!-- device -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${model}"'</td> <!-- model -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${serial}"'</td> <!-- serial -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${capacity}"'</td> <!-- capacity -->'
				echo '<td style="text-align:center; background-color:'"${smartStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${smartStatus}"'</td> <!-- smartStatusColor, smartStatus -->'
				echo '<td style="text-align:center; background-color:'"${tempColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${temp}"'</td> <!-- tempColor, temp -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${onTime}"'</td> <!-- onTime -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${startStop}"'</td> <!-- startStop -->'
				echo '<td style="text-align:center; background-color:'"${mediaErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${mediaErrors}"'</td> <!-- mediaErrorsColor, mediaErrors -->'
				echo '<td style="text-align:center; background-color:'"${errorsLogsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${errorsLogs}"'</td> <!-- errorsLogsColor, errorsLogs -->'
				echo '<td style="text-align:center; background-color:'"${critWarningColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${critWarning}"'</td> <!-- critWarningColor, critWarning -->'
				echo '<td style="text-align:center; background-color:'"${wearLevelingColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${wearLeveling}"'</td> <!-- wearLevelingColor, wearLeveling -->'
				echo '<td style="text-align:center; background-color:'"${totalBWColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${totalBW}"'</td> <!-- totalBWColor, totalBW -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${bwPerDay}"'</td> <!-- bwPerDay -->'
				echo '<td style="text-align:center; background-color:'"${testAgeColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">N/A</td> <!-- testAgeColor, testAge -->'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">N/A</td> <!-- lastTestType -->'
				echo '</tr>'
			} >> "${logfile}"
		fi
	done

	# End SMART summary table section
	{
		echo "</table>"
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function SSDSummary () {
	###### SSD SMART status summary table
    {
        # Write HTML table headers to log file
        echo '<br><br>'
        echo '<table style="border: 1px solid black; border-collapse: collapse;">'
        echo '<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">SSD SMART Status Report Summary</th></tr>'
        echo '<tr>'
        echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>'
        echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>'
        echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>'
        echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>'
        echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>('"${powerTimeFormat}"')</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power<br>Cycle<br>Count</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Sectors</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Program<br>Fail<br>Count</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Erase<br>Fail<br>Count</th>'
        echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Offline<br>Uncorrectable<br>Sectors</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">CRC<br>Errors</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Wear<br>Leveling<br>Count</th>'
        echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Total<br>Bytes<br>Written</th>'
        echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Bytes Written<br>(per Day)</th>'
        echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>'
        echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>'
        echo '</tr>'
    } >> "${logfile}"

	local drive
	local altRow="false"
    for drive in "${drives[@]}"; do
		local ssdInfoSmrt="$(smartctl -AHijl selftest --log="devstat" "/dev/${drive}")"
    	local rotTst="$(echo "${ssdInfoSmrt}" | jq -Mre '.rotation_rate | values')"
    	local scsiTst="$(echo "${ssdInfoSmrt}" | jq -Mre '.device.type | values')"
        if [ "${rotTst}" = "0" ] && [ ! "${scsiTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl selftest" and parse its output.
			# Start by parsing out the variables used in other parts of the script.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.
			local device="${drive}"

			# Available if any tests have completed
			local lastTestHours="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
			local lastTestType="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
			local lastTestStatus="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"

			# Available for any drive smartd knows about
			if [ "$(echo "${ssdInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${ssdInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${ssdInfoSmrt}" | jq -Mre '.serial_number | values')"

			local capacity="$(smartctl -i "/dev/${drive}" | grep '^User Capacity:' | tr -s ' ' | cut -d ' ' -sf '5,6')" # FixMe: have not yet figured out how to best calculate this from json values

			local temp="$(echo "${ssdInfoSmrt}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${ssdInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${ssdInfoSmrt}" | jq -Mre '.power_cycle_count | values')"
			local sectorSize="$(echo "${ssdInfoSmrt}" | jq -Mre '.logical_block_size | values')"

			# Available for most common drives
			local reAlloc="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 5) | .raw.value | values')"
			local progFail="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 171) | .raw.value | values')"
			local eraseFail="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 172) | .raw.value | values')"
			local offlineUnc="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 187) | .raw.value | values')"
			local crcErrors="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 199) | .raw.value | values')"

			# No standard attribute for % ssd life remanining
			local wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 173) | .value | values')"
			if [ -z "${wearLeveling}" ]; then
				wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 231) | .value | values')"
				if [ -z "${wearLeveling}" ]; then
					wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 233) | .value | values')"
					if [ -z "${wearLeveling}" ]; then
						wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 177) | .value | values')"
					fi
				fi
			fi

			# Get LBA written from the stats page for data written
			if [ ! -z "$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_device_statistics.pages[0] | values')" ]; then
				local totalLBA="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_device_statistics.pages[0].table[] | select(.name == "Logical Sectors Written") | .value | values')"
			else
				local totalLBA="0"
			fi


			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
			fi

			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# Colorize Temp
			if [ "${temp:="0"}" -ge "${ssdTempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp}" -ge "${ssdTempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize Sector Errors
			if [ "${reAlloc:=0}" -gt "${sectorsCrit}" ]; then
				local reAllocColor="${critColor}"
			elif [ ! "${reAlloc}" = "0" ]; then
				local reAllocColor="${warnColor}"
			else
				local reAllocColor="${bgColor}"
			fi

			# Colorize Program Fail
			if [ "${progFail:=0}" -gt "${sectorsCrit}" ]; then
				local progFailColor="${critColor}"
			elif [ ! "${progFail}" = "0" ]; then
				local progFailColor="${warnColor}"
			else
				local progFailColor="${bgColor}"
			fi

			# Colorize Erase Fail
			if [ "${eraseFail:=0}" -gt "${sectorsCrit}" ]; then
				local eraseFailColor="${critColor}"
			elif [ ! "${eraseFail}" = "0" ]; then
				local eraseFailColor="${warnColor}"
			else
				local eraseFailColor="${bgColor}"
			fi

			# Colorize Offline Uncorrectable
			if [ "${offlineUnc:=0}" -gt "${sectorsCrit}" ]; then
				local offlineUncColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ]; then
				local offlineUncColor="${warnColor}"
			else
				local offlineUncColor="${bgColor}"
			fi

			# Colorize CRC Errors
			if [ ! "${crcErrors:=0}" = "0" ]; then
				local crcErrorsColor="${warnColor}"
			else
				local crcErrorsColor="${bgColor}"
			fi

			# Colorize Wear Leveling
			if [ ! -z "${wearLeveling}" ]; then
				if [ "${wearLeveling}" -le "${lifeRemainCrit}" ]; then
					local wearLevelingColor="${critColor}"
				elif [ "${wearLeveling}" -le "${lifeRemainWarn}" ]; then
					local wearLevelingColor="${warnColor}"
				else
					local wearLevelingColor="${bgColor}"
				fi
			fi

			# Colorize & derive write stats
			local totalBW="$(bc <<< "scale=1; (${totalLBA} * ${sectorSize}) / (1000^4)" | sed -e 's:^\.:0.:')"
			if (( $(bc -l <<< "${totalBW} > ${totalBWCrit}") )); then
				local totalBWColor="${critColor}"
			elif (( $(bc -l <<< "${totalBW} > ${totalBWWarn}") )); then
				local totalBWColor="${warnColor}"
			else
				local totalBWColor="${bgColor}"
			fi
			if [ "${totalBW}" = "0.0" ]; then
				totalBW="N/A"
			else
				totalBW="${totalBW}TB"
			fi
			# Try to not divide by zero
			if [ ! "0" = "$(bc <<< "scale=1; ${onHours} / 24")" ]; then
				local bwPerDay="$(bc <<< "scale=1; (((${totalLBA} * ${sectorSize}) / (1000^4)) * 1000) / (${onHours} / 24)" | sed -e 's:^\.:0.:')"
				if [ "${bwPerDay}" = "0.0" ]; then
					bwPerDay="N/A"
				else
					bwPerDay="${bwPerDay}GB"
				fi
			else
				local bwPerDay="N/A"
			fi

			# Colorize test age
			if [ "${testAge:-0}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


            {
				# Row Output
				echo '<tr style="background-color:'"${bgColor}"';">'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"/dev/${device}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${model}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${serial}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${capacity}"'</td>'
				echo '<td style="text-align:center; background-color:'"${smartStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${smartStatus}"'</td>'
				echo '<td style="text-align:center; background-color:'"${tempColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${temp}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${onTime}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${startStop}"'</td>'
				echo '<td style="text-align:center; background-color:'"${reAllocColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${reAlloc}"'</td>'
				echo '<td style="text-align:center; background-color:'"${progFailColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${progFail}"'</td>'
				echo '<td style="text-align:center; background-color:'"${eraseFailColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${eraseFail}"'</td>'
				echo '<td style="text-align:center; background-color:'"${offlineUncColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${offlineUnc}"'</td>'
				echo '<td style="text-align:center; background-color:'"${crcErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${crcErrors}"'</td>'
				echo '<td style="text-align:center; background-color:'"${wearLevelingColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${wearLeveling:=N/A}"'%</td>'
				echo '<td style="text-align:center; background-color:'"${totalBWColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${totalBW}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${bwPerDay}"'</td>'
				echo '<td style="text-align:center; background-color:'"${testAgeColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${testAge:-"N/A"}"'</td>'
				echo '<td style="text-align:center; background-color:'"${lastTestStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${lastTestType:-"N/A"}"'</td>'
				echo '</tr>'
            } >> "${logfile}"
        fi
    done

    # End SSD SMART summary table
    {
        echo '</table>'
    } >> "${logfile}"
}

# shellcheck disable=SC2155
function HDDSummary () {
	###### HDD SMART status summary table
	{
		# Write HTML table headers to log file
		echo '<br><br>'
		echo '<table style="border: 1px solid black; border-collapse: collapse;">'
		echo '<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">HDD SMART Status Report Summary</th></tr>'
		echo '<tr>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>'
		echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>'
		echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">RPM</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>'
		echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>('"${powerTimeFormat}"')</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Start<br>Stop<br>Count</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Spin<br>Retry<br>Count</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Sectors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Events</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Current<br>Pending<br>Sectors</th>'
		echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Offline<br>Uncorrectable<br>Sectors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">CRC<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Seek<br>Error<br>Health</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>'
		echo '</tr>'
	} >> "${logfile}"

	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		local hddInfoSmrt="$(smartctl -AHijl selftest "/dev/${drive}")"
		local rotTst="$(echo "${hddInfoSmrt}" | jq -Mre '.rotation_rate | values')"
		local scsiTst="$(echo "${hddInfoSmrt}" | jq -Mre '.device.type | values')"
		if [ -z "${rotTst}" ] && [ ! -z "$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[]? | select(.name == "Spin_Up_Time") | .id | values')" ]; then
			rotTst="N/R"
		fi
		if [ ! "${rotTst:="0"}" = "0" ] && [ ! "${scsiTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl selftest" and parse its output.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			local device="${drive}"

			# Available if any tests have completed
			local lastTestHours="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
			local lastTestType="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
			local lastTestStatus="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"

			# Available for any drive smartd knows about
			if [ "$(echo "${hddInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${hddInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${hddInfoSmrt}" | jq -Mre '.serial_number | values')"
			local rpm="$(echo "${hddInfoSmrt}" | jq -Mre '.rotation_rate | values')"

			local capacity="$(smartctl -i "/dev/${drive}" | grep '^User Capacity:' | tr -s ' ' | cut -d ' ' -sf '5,6')" # FixMe: have not yet figured out how to best calculate this from json values

			local temp="$(echo "${hddInfoSmrt}"| jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${hddInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${hddInfoSmrt}" | jq -Mre '.power_cycle_count | values')"

			# Available for most common drives
			local reAlloc="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 5) | .raw.value | values')"
			local spinRetry="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 10) | .raw.value | values')"
			local reAllocEvent="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 196) | .raw.value | values')"
			local pending="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 197) | .raw.value | values')"
			local offlineUnc="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 198) | .raw.value | values')"
			local crcErrors="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 199) | .raw.value | values')"
			local seekErrorHealth="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 7) | .value | values')"


			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
			fi

			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# Colorize Temp
			if [ "${temp:="0"}" -ge "${tempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp}" -ge "${tempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize Spin Retry Errors
			if [ ! "${spinRetry:=0}" = "0" ]; then
				local spinRetryColor="${warnColor}"
			else
				local spinRetryColor="${bgColor}"
			fi

			# Colorize Sector Errors
			if [ "${reAlloc:=0}" -gt "${sectorsCrit}" ]; then
				local reAllocColor="${critColor}"
			elif [ ! "${reAlloc}" = "0" ]; then
				local reAllocColor="${warnColor}"
			else
				local reAllocColor="${bgColor}"
			fi

			# Colorize Sector Event Errors
			if [ ! "${reAllocEvent:=0}" = "0" ]; then
				local reAllocEventColor="${warnColor}"
			else
				local reAllocEventColor="${bgColor}"
			fi

			# Colorize Pending Sector
			if [ "${pending:=0}" -gt "${sectorsCrit}" ]; then
				local pendingColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ]; then
				local pendingColor="${warnColor}"
			else
				local pendingColor="${bgColor}"
			fi

			# Colorize Offline Uncorrectable
			if [ "${offlineUnc:=0}" -gt "${sectorsCrit}" ]; then
				local offlineUncColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ]; then
				local offlineUncColor="${warnColor}"
			else
				local offlineUncColor="${bgColor}"
			fi

			# Colorize CRC Errors
			if [ ! "${crcErrors:=0}" = "0" ]; then
				local crcErrorsColor="${warnColor}"
			else
				local crcErrorsColor="${bgColor}"
			fi

			# Colorize Seek Error
			if [ "${seekErrorHealth:=0}" -lt "100" ]; then
				local seekErrorHealthColor="${warnColor}"
			else
				local seekErrorHealthColor="${bgColor}"
			fi

			# Colorize test age
			if [ "${testAge:-0}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


			{
				# Row Output
				echo '<tr style="background-color:'"${bgColor}"';">'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"/dev/${device}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${model}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${serial}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${rpm}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${capacity}"'</td>'
				echo '<td style="text-align:center; background-color:'"${smartStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${smartStatus}"'</td>'
				echo '<td style="text-align:center; background-color:'"${tempColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${temp}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${onTime}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${startStop}"'</td>'
				echo '<td style="text-align:center; background-color:'"${spinRetryColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${spinRetry}"'</td>'
				echo '<td style="text-align:center; background-color:'"${reAllocColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${reAlloc}"'</td>'
				echo '<td style="text-align:center; background-color:'"${reAllocEventColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${reAllocEvent}"'</td>'
				echo '<td style="text-align:center; background-color:'"${pendingColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${pending}"'</td>'
				echo '<td style="text-align:center; background-color:'"${offlineUncColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${offlineUnc}"'</td>'
				echo '<td style="text-align:center; background-color:'"${crcErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${crcErrors}"'</td>'
				echo '<td style="text-align:center; background-color:'"${seekErrorHealthColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${seekErrorHealth}"'%</td>'
				echo '<td style="text-align:center; background-color:'"${testAgeColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${testAge:-"N/A"}"'</td>'
				echo '<td style="text-align:center; background-color:'"${lastTestStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${lastTestType:-"N/A"}"'</td>'
				echo '</tr>'
			} >> "${logfile}"
		fi
	done

	# End SMART summary table and summary section
	{
		echo '</table>'
		echo '<br><br>'
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function SASSummary () {
	###### SAS SMART status summary table
	{
		# Write HTML table headers to log file
		echo '<br><br>'
		echo '<table style="border: 1px solid black; border-collapse: collapse;">'
		echo '<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">SAS SMART Status Report Summary</th></tr>'
		echo '<tr>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>'
		echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>'
		echo '<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">RPM</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>'
		echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>('"${powerTimeFormat}"')</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Start<br>Stop<br>Cycles</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Load<br>Unload<br>Cycles</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Grown<br>Defect<br>List</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Read<br>Errors</th>'
		echo '<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Write<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Verify<br>Errors</th>'
		echo '<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Non-medium<br>Errors</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>'
		echo '<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>'
		echo '</tr>'
	} >> "${logfile}"

	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		local sasInfoSmrt="$(smartctl -AHijl selftest "/dev/${drive}")"
		local nonJsonSasInfoSmrt="$(smartctl -Al error -l selftest "/dev/${drive}")"
		local rotTst="$(echo "${sasInfoSmrt}" | jq -Mre '.device.type | values')"
		if [ "${rotTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl selftest" and parse its output.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			local device="${drive}"

			# Available if any tests have completed #FixMe this info is not currently exported in json for sas drives
			local lastTestHours="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
			local lastTestType="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
			local lastTestStatus="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"

			#FixMe: relies on non-json output
			lastTestHours="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '7')"
			lastTestType="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '3,4')"
			lastTestStatus="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '8,9,10,11')"

			# Mimic the true/false response expected from json in the future
			if [ "${lastTestStatus}" = "- [- - -]" ]; then
				lastTestStatus="true"
			else
				# Workaround for some drives that do not support self testing but still report a garbage self test log
				# Set last test type to 'N/A' and last test hours to null "" in this case.  Do not colorize test status as a failure.
				if [ "${lastTestType}" == "Default Self" ]; then
					lastTestType="N/A"
					lastTestHours=""
					lastTestStatus="true"
				else
					lastTestStatus="false"
				fi
			fi

			# Available for any drive smartd knows about
			if [ "$(echo "${sasInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${sasInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${sasInfoSmrt}" | jq -Mre '.serial_number | values')"
			local rpm="$(echo "${sasInfoSmrt}" | jq -Mre '.rotation_rate | values')"
			# SAS drives may be SSDs or HDDs
			if [ "${rpm:-0}" = "0" ]; then
				rpm="SSD"
			fi

			local capacity="$(smartctl -i "/dev/${drive}" | grep '^User Capacity:' | tr -s ' ' | cut -d ' ' -sf '5,6')" # FixMe: have not yet figured out how to best calculate this from json values

			local temp="$(echo "${sasInfoSmrt}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${sasInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"

			# Available for most common drives
			local scsiGrownDefectList="$(echo "${sasInfoSmrt}" | jq -Mre '.scsi_grown_defect_list | values')"
			local uncorrectedReadErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.read.total_uncorrected_errors | values')"
			local uncorrectedWriteErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.write.total_uncorrected_errors | values')"
			local uncorrectedVerifyErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.verify.total_uncorrected_errors | values')"

			#FixMe: relies on non-json output
			local nonMediumErrors="$(echo "${nonJsonSasInfoSmrt}" | grep "Non-medium" | tr -s " " | cut -d ' ' -sf '4')"
			local accumStartStopCycles="$(echo "${nonJsonSasInfoSmrt}" | grep "Accumulated start-stop" | tr -s " " | cut -d ' ' -sf '4')"
			local accumLoadUnloadCycles="$(echo "${nonJsonSasInfoSmrt}" | grep "Accumulated load-unload" | tr -s " " | cut -d ' ' -sf '4')"

			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
			fi

			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# SAS is both SSD and HDD; colorize temp as appropriate
			if [ "${rpm}" = "SSD" ]; then
				# SAS SSD
				if [ "${temp:="0"}" -ge "${ssdTempCrit}" ]; then
					local tempColor="${critColor}"
				elif [ "${temp}" -ge "${ssdTempWarn}" ]; then
					local tempColor="${warnColor}"
				else
					local tempColor="${bgColor}"
				fi
			else
				# SAS HDD
				if [ "${temp:="0"}" -ge "${tempCrit}" ]; then
					local tempColor="${critColor}"
				elif [ "${temp}" -ge "${tempWarn}" ]; then
					local tempColor="${warnColor}"
				else
					local tempColor="${bgColor}"
				fi
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize scsi Grown Defect List Errors
			if [ "${scsiGrownDefectList:=0}" -gt "${sectorsCrit}" ]; then
				local scsiGrownDefectListColor="${critColor}"
			elif [ ! "${scsiGrownDefectList}" = "0" ]; then
				local scsiGrownDefectListColor="${warnColor}"
			else
				local scsiGrownDefectListColor="${bgColor}"
			fi

			# Colorize Read Errors
			if [ ! "${uncorrectedReadErrors:=0}" = "0" ]; then
				local uncorrectedReadErrorsColor="${warnColor}"
			else
				local uncorrectedReadErrorsColor="${bgColor}"
			fi

			# Colorize Write Errors
			if [ ! "${uncorrectedWriteErrors:=0}" = "0" ]; then
				local uncorrectedWriteErrorsColor="${warnColor}"
			else
				local uncorrectedWriteErrorsColor="${bgColor}"
			fi

			# Colorize Verify Errors
			if [ ! "${uncorrectedVerifyErrors:=0}" = "0" ]; then
				local uncorrectedVerifyErrorsColor="${warnColor}"
			else
				local uncorrectedVerifyErrorsColor="${bgColor}"
			fi

			# Colorize test age
			if [ "${testAge:-0}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi

			{
				# Row Output
				echo '<tr style="background-color:'"${bgColor}"';">'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"/dev/${device}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${model}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${serial}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${rpm}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${capacity}"'</td>'
				echo '<td style="text-align:center; background-color:'"${smartStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${smartStatus}"'</td>'
				echo '<td style="text-align:center; background-color:'"${tempColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${temp}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${onTime}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${accumStartStopCycles}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${accumLoadUnloadCycles}"'</td>'
				echo '<td style="text-align:center; background-color:'"${scsiGrownDefectListColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${scsiGrownDefectList}"'</td>'
				echo '<td style="text-align:center; background-color:'"${uncorrectedReadErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${uncorrectedReadErrors}"'</td>'
				echo '<td style="text-align:center; background-color:'"${uncorrectedWriteErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${uncorrectedWriteErrors}"'</td>'
				echo '<td style="text-align:center; background-color:'"${uncorrectedVerifyErrorsColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${uncorrectedVerifyErrors}"'</td>'
				echo '<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${nonMediumErrors}"'</td>'
				echo '<td style="text-align:center; background-color:'"${testAgeColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${testAge:-"N/A"}"'</td>'
				echo '<td style="text-align:center; background-color:'"${lastTestStatusColor}"'; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">'"${lastTestType:-"N/A"}"'</td>'
				echo '</tr>'
			} >> "${logfile}"
		fi
	done

	# End SMART summary table and summary section
	{
		echo '</table>'
		echo '<br><br>'
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function ReportUPS () {
    # Set to a value greater than zero to include all available UPSC
    # variables in the report:
	local senddetail="0"
	local ups
    local upslist

    # Get a list of all ups devices installed on the system:
    readarray -t "upslist" <<< "$(upsc -l "${host}")"

    {
		echo '<b>########## UPS status report ##########</b>'
			for ups in "${upslist[@]}"; do

				local ups_type="$(upsc "${ups}" device.type 2> /dev/null | tr '[:lower:]' '[:upper:]')"
				local ups_mfr="$(upsc "${ups}" ups.mfr 2> /dev/null)"
				local ups_model="$(upsc "${ups}" ups.model 2> /dev/null)"
				local ups_serial="$(upsc "${ups}" ups.serial 2> /dev/null)"
				local ups_status="$(upsc "${ups}" ups.status 2> /dev/null)"
				local ups_load="$(upsc "${ups}" ups.load 2> /dev/null)"
				local ups_realpower="$(upsc "${ups}" ups.realpower 2> /dev/null)"
				local ups_realpowernominal="$(upsc "${ups}" ups.realpower.nominal 2> /dev/null)"
				local ups_batterycharge="$(upsc "${ups}" battery.charge 2> /dev/null)"
				local ups_batteryruntime="$(upsc "${ups}" battery.runtime 2> /dev/null)"
				local ups_batteryvoltage="$(upsc "${ups}" battery.voltage 2> /dev/null)"
				local ups_inputvoltage="$(upsc "${ups}" input.voltage 2> /dev/null)"
				local ups_outputvoltage="$(upsc "${ups}" output.voltage 2> /dev/null)"

				printf "=== %s %s, model %s, serial number %s\n\n" "${ups_mfr}" "${ups_type}" "${ups_model}" "${ups_serial} ==="
				echo "Name: ${ups}"
				echo "Status: ${ups_status}"
				echo "Output Load: ${ups_load}%"
				if [ ! -z "${ups_realpower}" ]; then
					echo "Real Power: ${ups_realpower}W"
				fi
				if [ ! -z "${ups_realpowernominal}" ]; then
					echo "Real Power: ${ups_realpowernominal}W (nominal)"
				fi
				if [ ! -z "${ups_inputvoltage}" ]; then
					echo "Input Voltage: ${ups_inputvoltage}V"
				fi
				if [ ! -z "${ups_outputvoltage}" ]; then
					echo "Output Voltage: ${ups_outputvoltage}V"
				fi
				echo "Battery Runtime: ${ups_batteryruntime}s"
				echo "Battery Charge: ${ups_batterycharge}%"
				echo "Battery Voltage: ${ups_batteryvoltage}V"
				echo ""
				if [ "${senddetail}" -gt "0" ]; then
					echo "=== ALL AVAILABLE UPS VARIABLES ==="
					upsc "${ups}"
					echo ""
				fi
			done
    } >> "${logfile}"

    echo "<br><br>" >> "${logfile}"
}


#
# Main Script Starts Here
#

while getopts ":c:" OPTION; do
	case "${OPTION}" in
		c)
			configFile="${OPTARG}"
		;;
		?)
			# If an unknown flag is used (or -?):
			echo "${0} {-c configFile}" >&2
			exit 1
		;;
	esac
done

if [ -z "${configFile}" ]; then
	echo "Please specify a config file location; if none exist one will be created." >&2
	exit 1
elif [ ! -f "${configFile}" ]; then
	rpConfig
fi

# Source external config file
# shellcheck source=/dev/null
. "${configFile}"

# Check if needed software is installed.
PATH="${PATH}:/usr/local/sbin:/usr/local/bin"
commands=(
hostname
date
sysctl
sed
grep
awk
zpool
cut
tr
bc
smartctl
jq
glabel
head
tail
sendmail
)
if [ "${configBackup}" = "true" ]; then
commands+=(
tar
sqlite3
md5
sha256
base64
)
fi
if [ "${reportUPS}" = "true" ]; then
commands+=(
upsc
)
fi
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		echo "${command} is missing, please install" >&2
		exit 100
	fi
done


# Do not run if the config file has not been edited.
if [ ! "${defaultFile}" = "0" ]; then
	echo "Please edit the config file for your setup" >&2
	exit 1
fi


###### Auto-generated Parameters
host="$(hostname -s)"
fromEmail="$(sqlite3 /data/freenas-v1.db "select em_fromemail from system_email;")"
fromName="$(sqlite3 /data/freenas-v1.db "select em_fromname from system_email;")"
runDate="$(date '+%s')"
logfile="${logfileLocation}/$(date -r "${runDate}" '+%Y%m%d%H%M%S')_${logfileName}.tmp"
subject="Status Report and Configuration Backup for ${host} - $(date -r "${runDate}" '+%Y-%m-%d %H:%M')"
boundary="$(dbus-uuidgen)"
messageid="$(dbus-uuidgen)"

# Reorders the drives in ascending order
# FixMe: smart support flag is not yet implemented in smartctl json output.
readarray -t "drives" <<< "$(for drive in $(sysctl -n kern.disks | sed -e 's:nvd:nvme:g'); do
	if smartctl --json=u -i "/dev/${drive}" | grep "SMART support is:" | grep -q "Enabled"; then
		printf "%s " "${drive}"
	elif echo "${drive}" | grep -q "nvme"; then
		printf "%s " "${drive}"
	fi
done | awk '{for (i=NF; i!=0 ; i--) print $i }')"

# Toggles the 'ssdExist' flag to true if SSDs are detected in order to add the summary table
if [ "${includeSSD}" = "true" ]; then
    for drive in "${drives[@]}"; do
        if [ "$(smartctl -ij "/dev/${drive}" | jq -Mre '.rotation_rate | values')" = "0" ] && [ ! "$(smartctl -ij "/dev/${drive}" | jq -Mre '.device.type | values')" = "scsi" ]; then
            ssdExist="true"
            break
        else
            ssdExist="false"
        fi
    done
    if echo "${drives[*]}" | grep -q "nvme"; then
    	NVMeExist="true"
    fi
fi
# Test to see if there are any HDDs
for drive in "${drives[@]}"; do
	if [ ! "$(smartctl -ij "/dev/${drive}" | jq -Mre '.rotation_rate | values')" = "0" ] && [ ! "$(smartctl -ij "/dev/${drive}" | jq -Mre '.device.type | values')" = "scsi" ]; then
		hddExist="true"
		break
	else
		hddExist="false"
	fi
done
# Test to see if there are any SAS drives
for drive in "${drives[@]}"; do
	if [ "$(smartctl -ij "/dev/${drive}" | jq -Mre '.device.type | values')" = "scsi" ]; then
		sasExist="true"
		break
	else
		sasExist="false"
	fi
done

# Get a list of pools
readarray -t "pools" <<< "$(zpool list -H -o name)"



###### Email pre-formatting
### Set email headers
{
    echo "From: ${fromName:="${host}"} <${fromEmail:="root@$(hostname)"}>"
    echo "To: ${email}"
    echo "Subject: ${subject}"
    echo "MIME-Version: 1.0"
    echo 'Content-Type: multipart/mixed; boundary="'"${boundary}"'"'
    echo "Date: $(date -Rr "${runDate}")"
    echo "Message-Id: <${messageid}@${host}>"
} > "${logfile}"




###### Config backup (if enabled)
if [ "${configBackup}" = "true" ]; then
	ConfigBackup
else
    # Config backup disabled; set up for html-type content
    {
        echo "--${boundary}"
        echo "Content-Transfer-Encoding: 8bit"
        echo -e "Content-Type: text/html; charset=utf-8\n"
    } >> "${logfile}"
fi


###### Report Summary Section (html tables)

ZpoolSummary


### SMART status summary tables


if [ "${NVMeExist}" = "true" ]; then
	NVMeSummary
fi


if [ "${sasExist}" = "true" ]; then
	SASSummary
fi


if [ "${ssdExist}" = "true" ]; then
	SSDSummary
fi


if [ "${hddExist}" = "true" ]; then
	HDDSummary
fi



###### Detailed Report Section (monospace text)
echo '<pre style="font-size:14px">' >> "${logfile}"


### UPS status report
if [ "${reportUPS}" = "true" ]; then
	ReportUPS
fi


### Print Glabel Status
{
    echo '<b>########## Glabel Status ##########</b>'
    glabel status
    echo '<br><br>'
} >> "${logfile}"


### Zpool status for each pool
for pool in "${pools[@]}"; do
    {
        # Create a simple header and drop the output of zpool status -v
        echo '<b>########## ZPool status report for '"${pool}"' ##########</b>'
        zpool status -v "${pool}"
        echo '<br><br>'
    } >> "${logfile}"
done


### SMART status for each drive
for drive in "${drives[@]}"; do
    smartOut="$(smartctl --json=u -i "/dev/${drive}")" # FixMe: smart support flag is not yet implemented in smartctl json output.
    smartTestOut="$(smartctl -l selftest "/dev/${drive}")"

    if echo "${smartOut}" | grep "SMART support is:" | grep -q "Enabled"; then # FixMe: smart support flag is not yet implemented in smartctl json output.
        # Gather brand and serial number of each drive
        brand="$(echo "${smartOut}" | jq -Mre '.model_family | values')"
        if [ -z "${brand}" ]; then
            brand="$(echo "${smartOut}" | jq -Mre '.model_name | values')";
        fi
        serial="$(echo "${smartOut}" | jq -Mre '.serial_number | values')"
        {
            # Create a simple header and drop the output of some basic smartctl commands
            echo '<b>########## SMART status report for '"${drive}"' drive ('"${brand}: ${serial}"') ##########</b>'
            smartctl -H -A -l error "/dev/${drive}"
            echo "${smartTestOut}" | grep 'Num' | cut -c6- | head -1
            echo "${smartTestOut}" | grep 'Extended' | cut -c6- | head -1
            echo "${smartTestOut}" | grep 'Short' | cut -c6- | head -1
            echo "${smartTestOut}" | grep 'Conveyance' | cut -c6- | head -1
            echo '<br><br>'
        } >> "${logfile}"

    elif echo "${drive}" | grep -q "nvme"; then
    	# NVMe drives are handled separately because self tests are not yet supported.
        # Gather brand and serial number of each drive
		brand="$(echo "${smartOut}" | jq -Mre '.model_family | values')"
        if [ -z "${brand}" ]; then
            brand="$(echo "${smartOut}" | jq -Mre '.model_name | values')";
        fi
		serial="$(echo "${smartOut}" | jq -Mre '.serial_number | values')"
		{
			# Create a simple header and drop the output of some basic smartctl commands
            echo '<b>########## SMART status report for '"${drive}"' drive ('"${brand}: ${serial}"') ##########</b>'
            smartctl -H -A -l error "/dev/${drive}"
            echo '<br><br>'
		} >> "${logfile}"
    fi
done

# Remove some un-needed junk from the output
sed -i '' -e '/smartctl [6-9].[0-9]/d' "${logfile}"
sed -i '' -e '/Copyright/d' "${logfile}"
sed -i '' -e '/=== START OF READ/d' "${logfile}"
sed -i '' -e '/=== START OF SMART DATA SECTION ===/d' "${logfile}"
sed -i '' -e '/SMART Attributes Data/d' "${logfile}"
sed -i '' -e '/Vendor Specific SMART/d' "${logfile}"
sed -i '' -e '/SMART Error Log Version/d' "${logfile}"

### End details section, close MIME section
(
    echo '</pre>'
    echo "--${boundary}--"
)  >> "${logfile}"

### Send report
sendmail -t -oi < "${logfile}"
if [ "${saveLogfile}" = "false" ]; then
    rm "${logfile}"
fi
