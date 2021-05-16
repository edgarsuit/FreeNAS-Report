# ZPool, SMART, and UPS Status Report with TrueNAS Config Backup
Original Script By: joeschmuck<br>
Modified By: bidelu0hm, melp, fohlsso2, onlinepcwizard, ninpucho, isentropik, rotx, dak180<br>
Last Edited By: dak180

Preview of the output here: https://i.imgur.com/jKwraw4.png<br>
When a resilver is in progress: https://i.imgur.com/CUNUZ7r.png<br>
After the resilver is done: https://i.imgur.com/I43MLLf.png<br>
When a scrub is in progess: https://i.imgur.com/YGmvZT4.png<br><br>

**At a minimum, enter email address and set defaultFile to 0 in the generated config file. Feel free to edit other user parameters as needed. Backup has been disabled by default so if it is required please set to true.**<br><br>

**Current Version: v1.7**

**Changelog:**

*v1.7* (dak180)
 - Refactor to reduce dependence on awk
 - Use a separate config file
 - Add support for conveyance test

*v1.6.5* (rotx)
 - HTML boundary fix, proper message ids, support for dma mailer
 - Better support for NVMe and SSD
 - Support for new smartmon-tools

*v1.6* (isentropik)
 - Actually fixed the broken borders in the tables.
 - Split the SMART table into two tables, one for SSDs and one for HDDs.
 - Added several options for SSD reporting.
 - Modified the SSD table in order to capture relevant (seemingly) SSD data.
 - Changed 'include SSD' default to true.
 - Cleaned up minor formatting and error handling issues (tried to have the cell fill with "N/A" instead of non-sensical values).

*v1.5* (ninpucho)
 - Added Frag%, Size, Allocated, Free for ZPool status report summary.
 - Added Disk Size, RPM, Model to the Smart Report
 - Added if statment so that if "Model Family" is not present script will use "Device Model"
      for brand in the SMART Satus report details.
 - Added Glabel Status Report
 - Removed Power-On time labels and added ":" as a separator.
 - Added Power-On format to the Power-On time Header.
 - Changed Backup deafult to false.

*v1.4* (onlinepcwizard)
- fixed the broken border on zpool status summary header
- in statusOutput changed grep to scrub: instead of scrub
- added elif for resilvered/resilver in progress and scrub in progress with (hopefully) som useful info fields
- changed the email subject to include hostname and date & time
- aaand fixed the parser

*v1.3*
- Added scrub duration column
- Fixed for FreeNAS 11.1 (thanks reven!)
- Fixed fields parsed out of zpool status
- Buffered zpool status to reduce calls to script

*v1.2*
- Added switch for power-on time format
- Slimmed down table columns
- Fixed some shellcheck errors & other misc stuff
- Added .tar.gz to backup file attached to email
- (Still coming) Better SSD SMART support

*v1.1*
- Config backup now attached to report email
- Added option to turn off config backup
- Added option to save backup configs in a specified directory
- Power-on hours in SMART summary table now listed as YY-MM-DD-HH
- Changed filename of config backup to exclude timestamp (just uses datestamp now)
- Config backup and checksum files now zipped (was just .tar before; now .tar.gz)
- Fixed degrees symbol in SMART table (rendered weird for a lot of people); replaced with a *
- Added switch to enable or disable SSDs in SMART table (SSD reporting still needs work)
- Added most recent Extended & Short SMART tests in drive details section (only listed one before, whichever was more recent)
- Reformatted user-definable parameters section
- Added more general comments to code

*v1.0*
- Initial release
