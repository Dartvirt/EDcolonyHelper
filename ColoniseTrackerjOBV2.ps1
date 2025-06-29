######################################################################################################
# ColoniseTracker
# Part of Dart's colonisation script set
# Watches ED journals and updates progress files containing commodity movements for ED colonisation purposes
######################################################################################################

using namespace System.Windows.Forms
add-type -AssemblyName  System.Windows.Forms
$host.ui.RawUI.WindowTitle = 'Colonisation Tracker Console'

$scriptpath =$MyInvocation.MyCommand.Path
if ($scriptpath -eq $null) {$homedir = "C:\data\Scripts\Colonise\"} else {$homedir = (split-path $scriptpath )+ "\"}
$templateDir = "$homedir\templates\"
$usr = $env:USERNAME
$journalpath = "C:\users\$usr\Saved Games\Frontier Developments\Elite Dangerous\"
$monitorScript = $homedir+"ColoniseMonitorGUIV2.ps1"
#$carrierRego = "H0N-B2L"  # removed, now kept in carrier progress file. future - allows for possible multiple carriers
$cargofileVar = $journalpath + "cargo.json"  # this file appears in the journal direcory, not uset Yet
$ColoniserVar = "^System Colonisation Ship|^Planetary Construction Site:|^Orbital Construction Site:"
$dbgfile = $Homedir+"debug.txt"
$progressfile = $homedir+"ProgressBAD.csv" # shouldn't be using this but don't want to overwrite original accidentally during testing
$progressDir = $homedir+"Progress\" 
$UnknownDepotsfile = $homedir+"UnknownDepots.txt" 
$padFile = $homedir+"padlookup.csv" 
#$carrierfile = $progressDir+"_carrier.json"  
#$shipfile = $progressDir+"_ship.json"
#$GLOBAL:depotfile = $null # not using any more, calculated from $GLOBAL:depotName when needed instead.
$GLOBAL:depotName = $null
$statusfile = $homedir+"statusV2.json"
$padlookup = [hashtable]::new()
import-csv $padfile |foreach {$padlookup.add($_.ship.Tolower(),$_.pad[0])}

$lastWrite = $null
if ($job -ne $null) {$job.stopJob()}

function sum($a) {
    $S= 0
    $a |foreach {$S = $S + $_}
    $s
    }

class TStatus {
[string]$version = "2.5"
[string]$heartbeat
[string]$comment
[int64]$ProcessID
[int64]$cargoCapacity
[string]$Ship
[string]$ShipName
[string]$pad
[string]$starsystem
[string]$activeDepot = "Not Used" # moved to dedicated file managed by monitor, kept for backward compatibility
[string]$lastDepot
}

class Tcommodity {
[string]$Name
[string]$Type
[INT64]$Required
[INT64]$Have
}

Class Tlocation {
[string]$name
[string]$starSystem
[string]$kind
[string]$comment
[string]$Registration
[Tcommodity[]]$commodities
}


 function JOBScript {

function new-commodity ([string]$name,[string]$type,[int64]$count) {
$obj = new-object -TypeName psobject |select Name,Type,Required,Delivered,Ship,Carrier,Remaining
$obj.name = $name
$obj.type = $type
$obj.ship = $count
$obj.Required = 0
$obj.Delivered = 0
$obj.Carrier = 0
$obj.Remaining = 0
$obj
}

function remove-hash ($loc) {
   write-host remove hash start ($loc.name) ($loc.starsystem)
    $values = $loc.hash.values
    $loc.commodities = $values |sort type
    $loc |select name,starsystem,kind,comment,registration,commodities
}

function save-location ($location) {
   if ($location -ne $null) {
        $loc = remove-hash $location
        write-host Saving location  ($loc.name) ($loc.starsystem)
        $json = $loc|convertTo-json
        $fname = $progressDir + $location.name + ".json"
        $json |out-file $fname
    }
}

function save-progress {
    save-location $Global:depot
    save-location $Global:carrier
    save-location $Global:ship
}

function add-hash ($loc) {
    $hash = [hashtable]::new()
    $loc.commodities |foreach {$hash.add($_.type,$_)}
    $loc |add-member -MemberType NoteProperty -Name hash -value $hash
    $loc
}

function load-location ($Dname) {
   if ($Dname -ne $null) {
        $fname = $progressDir+$Dname+".json"
        try {
        $json = get-content $fname 
        $location = convertfrom-json "$json"
        $location = add-hash $location
        $location.name = $Dname
        $location }
        catch {$null} # if we cant load return nothing
        write-host LOADED ($location.kind) ($location.name) ($location.starsystem)
    }
} 

function test-location ($Dname) {
   if ($Dname -ne $null) {test-path ($progressDir+$Dname+".json")}
                    else {$false}
} 

function load-progress {
    $Global:depot = load-location $GLOBAL:depotName
    $Global:carrier = load-location "_carrier" 
    $Global:ship = load-location "_ship"
    $GLOBAL:carrierRego = $Global:carrier.registration
    write-host Loaded Carrier $GLOBAL:carrierRego and Ship
}

function out-debug ($TXT) {
    # $TXT|out-file $dbgfile -Append
    write-host $TXT
}

function move-cargo ($from,$to,$type,$qty) {
      $F= $from.name ; if ($F -eq $null) {$F = "market"}
      $T = $to.name ; if ($T -eq $null) {$T = "market"}
        out-debug  "Moving from $F to $T : $qty of $type"
        if ($from -ne $null)  {if ($type -in $from.hash.keys) {$from.hash.$type.have = [int64]($from.hash.$type.have) -[int64]$qty} }
        if ($to -ne $null)  {if ($type -in $to.hash.keys) {$to.hash.$type.have = [int64]($to.hash.$type.have) + [int64]$qty}
                             else {  # only used to insert a missing type, not needed yet but maybe in a future version the carrier and ship files will be trimmed of unused types.
                             $newcom =[Tcommodity]::new()
                             $ref = $Global:commodities.hash.Type
                             $newcom.name = $ref.name
                             $newcom.type = $ref.type
                             $newcom.required = -1
                             $newcom.have = $ref.qty
                             $to.hash.add($type,$newcom)} 
                            }
}

function Process-event ($line) {
 try {$E = convertfrom-json "$line"} 
 catch {
        write-host BAD JSON: $line; $E = $null}
  $event = $E.event 
  $starSystem = $E.StarSystem
  if ($starSystem -ne $null) {$GLOBAL:CurrentStarsystem = $starSystem}
  out-debug "read line" 
  out-debug $event 

    if ($event -eq "CargoTransfer") {
            $T = $E.Transfers; $T |Foreach {
                            $type = ($_.Type) 
                            $direction = ($_.direction)
                            $count = ($_.Count) 

                           # write-host $event $type $count $direction
                            if ($_.direction -eq "toship")   { move-cargo $GLOBAL:carrier $GLOBAL:ship $type $count }
                                                        else { move-cargo $GLOBAL:ship $GLOBAL:carrier $type $count}
                                        }
                           # $prog.values  |sort Name|ft name,required,delivered,ship,carrier,remaining
                            save-progress;$progressfileTS =get-date
                          } # if cargotransfer

  if ($event -eq "MarketBuy") {
                            $type = $E.type
                            $count = $E.count
                            write-host "BOUGHT:" ($E.type_localised);
                            if ($global:loc -eq "carrier") { move-cargo $GLOBAL:carrier $GLOBAL:ship $type $count } else 
                                                           { move-cargo $null $GLOBAL:ship $type $count }
                            save-progress;$progressfileTS =get-date
                            
                           } # if marketbuy

  if (($event -eq "MarketSell") ) {
                                    $type = $E.type
                                    $count = $E.count
                                    # write-host "SOL TO CARRIER:" ($E.type_localised);
                                    
                                    if ($global:loc -eq "carrier") { move-cargo  $GLOBAL:ship $GLOBAL:carrier $type $count }else 
                                                                   { move-cargo $GLOBAL:ship $null $type $count }
                                     save-progress;$progressfileTS =get-date
                                                    
                           } # if marketsell

  if (($event -eq "CarrierDepositFuel") ) {
                                    $type = "tritium"
                                    $count = $E.Amount
                                     # write-host "Tritium transfer" ;
                                    move-cargo $GLOBAL:ship $null $type $count 
                                     save-progress;$progressfileTS =get-date

                           } # if CarrierDepositFuel



  if ($event -eq "Docked") {write-host $event ($E.StationName);
                                     $station = $E.StationName
                                     $Status.comment = "Docked: $station"
                                     $status |convertto-json |set-content $statusfile
                                     if ( $station -match "ColonisationShip") {$station = "System Colonisation Ship "+$status.starsystem}

                                     write-host Current Carrier: $carrierRego
                                     write-host Derived station name: $station;
                                     $global:loc = "market"
                                     $ShipCargo = (get-content $cargofile |convertfrom-json) #.inventory
                                     $ShipInventory = $ShipCargo.Inventory
                                     if ($Station -eq $carrierRego) {$global:loc = "carrier"}
                                     if ($Station -match $Coloniser) {
                                                                      $Array = @($station.split(":")) #
                                                                      $idx = $array.count -1
                                                                      $newcolony = $array[$idx].trim() # take part of name after : if present
                                                                      $GLOBAL:LastDepot = $newcolony
                                                                      $GLOBAL:LastDepotFullname = $E.StationName
                                                                      if (test-location $newcolony) 
                                                                             {$global:loc = "colony"} 
                                                                        else {$global:loc = "unknownColony"} 
                                                                      if ($GLOBAL:Depot.name -ine $newcolony) {
                                                                                    $GLOBAL:depotname = $newcolony
                                                                                    if ($global:loc -eq "colony") {
                                                                                         $GLOBAL:Depot = load-location $newcolony
                                                                                         $status.LastDepot = $newcolony
                                                                                         }
                                                                                    else {$status.LastDepot = $newcolony
                                                                                            $Uds = get-content $UnknownDepotsfile
                                                                                            if ($newcolony -notin $Uds) {$newcolony |out-file $UnknownDepotsfile -Append }
                                                                                            }
                                                                                    $status |convertto-json |set-content $statusfile
                                                                                                              }
                                                                            }
                           } # if docked


  if (($event -eq "ColonisationContribution") -and ($global:loc -eq "colony")) {
                            $E.contributions |foreach {
                                 $type = $_.Name.replace("$","").replace("_name;","").tolower()
                                 $count= [int64]($_.amount)
                                            move-cargo $GLOBAL:ship $GLOBAL:depot $type $count
                                }
                            save-location  $global:ship
                            save-location  $global:depot
                            write-host Updated KNOWN Colony ($global:depot.name)
                            } # if ColonisationContribution in KNOWN colony

  if (($event -eq "ColonisationContribution") -and ($global:loc -ne "colony")) {
                            $E.contributions |foreach {
                                 $type = $_.Name.replace("$","").replace("_name;","").tolower()
                                 $count= [int64]($_.amount)
                                            move-cargo $GLOBAL:ship $null         $type $count 
                                }
                            save-location  $global:ship
                            write-host Updated UNKNOWN Colony ($global:colony.name)
                            } # if ColonisationContribution in UNKNOWN colony

    # unknown colony, make a depot file
  if (($event -eq "ColonisationConstructionDepot")) {  #-and ($global:loc -ne "colony")
             $fname = ($ProgressDir + $GLOBAL:LastDepot + ".json")
             if ($true) {   #!(test-path $fname)
                        Write-host "Creating New depot:" $GLOBAL:LastDepot
                        $newDepot = [Tlocation]::new()
                        $NewDepot.name =  $GLOBAL:LastDepot
                        $NewDepot.starSystem = $GLOBAL:CurrentStarsystem
                        $newDepot.kind = "Depot"
                        $newDepot.comment = "Discovered Depot "+ $GLOBAL:LastDepotFullname
                        $list = $E.resourcesRequired |sort name_localised
                        $list |foreach {
                                $c= [Tcommodity]::new()
                                $c.type = $_.Name.replace("$","").replace("_name;","").tolower()
                                $c.name = $_.Name_Localised
                                $c.required = $_.requiredAmount
                                $c.Have = $_.ProvidedAmount
                                $NewDepot.commodities = $NewDepot.commodities + $c
                                }
                        $json = $newDepot |convertto-json
                        $json |out-file $fname -force
                        add-hash $newDepot
                        $GLOBAL:Depot = $newDepot
                        $global:loc = "colony"
                        $status.LastDepot = $GLOBAL:LastDepot
                        $status |convertto-json |set-content $statusfile 
                        }
             }
<#
 if (($event -eq "ColonisationConstructionDepot") -and ($global:loc -eq "colony")) {
                        $list = $E.resourcesRequired |sort name_localised
                        $updated = @()
                        $list |foreach {
                                $c= [Tcommodity]::new()
                                $c.type = $_.Name.replace("$","").replace("_name;","").tolower()
                                $c.name = $_.Name_Localised
                                $c.required = $_.requiredAmount
                                $c.Have = $_.ProvidedAmount
                                $updated = $updated + $c
                                }
                        $GLOBAL:Depot.commodities = $updated 
                        Write-host "Updating depot:" $GLOBAL:LastDepot                    
             }
#>

  if ($event -eq "Cargo") {
            $count = $E.count
            $Inv = $E.Inventory
            if ($count -eq 0) {
                                $GLOBAL:ship.hash.keys |foreach {$t = $_;$GLOBAL:ship.hash.$t.have = 0}
                                save-location  $global:ship
                                Write-host ZERO SHIP CARGO EXPLICIT}
            if ($Inv.count -gt 0) {
                                $GLOBAL:ship.hash.keys |foreach {$t = $_;$GLOBAL:ship.hash.$t.have = 0}
                                $Inv |foreach {
                                                $t = $_.name
                                                $n = $_.name_localised
                                                $c = $_.count
                                                Write-host SET SHIP CARGO $t to $c
                                                if ($t -in $GLOBAL:ship.hash.keys) {$GLOBAL:ship.hash.$t.have = $c} else 
                                                                                     {$cmdty = [Tcommodity]::new()
                                                                                      $cmdty.name = $n
                                                                                      $cmdty.type = $t
                                                                                      $cmdty.required = -1
                                                                                      $cmdty.have = $c
                                                                                      $GLOBAL:ship.hash.add($t,$cmdty)
                                                                                     }
                                               }
                                save-location  $global:ship
                                
                                }



          } # if cargo

     #when docked at a market, copy the market data to the homedir, then delete when undocking
  if ($event -eq "Market") {
                            cp ($journalpath+"market.json") $homedir -force
                            }
  if ($event -eq "Undocked") {
                              if (test-path ($homedir+"market.json")) {rm ($homedir+"market.json")}
                            }
  if ($event -eq "Loadout") {
                             $status.cargoCapacity = $E.CargoCapacity
                             $status.Ship = $E.Ship
                             $status.ShipName = $E.ShipName
                             $status.pad = $padlookup.($E.Ship)
                            $status |convertto-json |set-content $statusfile
                            }
  if (($StarSystem -ne $null) -and ($StarSystem -ne $status.starsystem)) {
                            $status.StarSystem = $StarSystem
                            $status |convertto-json |set-content $statusfile
                            }
}

out-debug "START"

$GLOBAL:carrierRego = $carrierVar 
$cargofile = $cargofileVar
$Coloniser = $ColoniserVar
$JournalFile = $journalFullname

$lastfile = Get-ChildItem ($progressdir+"_*.json") |sort LastWriteTime |select -last 1
$progressDirTS = $lastfile.LastWriteTime 
#load-progress
$Global:commodities = load-location "_commodities"  # load reference file of all commodities

out-debug "STEP2" 
out-debug $Journalfile 
$jf=get-item $Journalfile
if (test-path $statusfile) {$json = get-content $statusfile;$status1 = convertFrom-json "$json";$status =[tstatus]$status1 } else {$status = [Tstatus]::new()}

$status.ProcessID = $PID
$Status.comment = $jf.name
$status |convertto-json |set-content $statusfile


#  Open Journal and stream new entries.

$F = get-item $Journalfile
$text = get-content $F.FullName
$linecount = $text.count
$Go = $true
$Len = $F.Length
while ($GO) {
    $F.Refresh()
    if ($len -ne $F.length)  {$text = get-content $F.FullName
                                $newlinecount = $text.count
                               if ($Newlinecount -gt $linecount) { $text[$linecount..($Newlinecount-1)] |foreach {process-event $_}}
                                $Linecount = $newlinecount
                                $len = $F.length
                            }

  # before processing a new entry, check if progress file was externally altered and reload if necessary
  $lastfile = Get-ChildItem ($progressdir+"_*.json") |sort LastWriteTime |select -last 1
  $checkTS =  $lastfile.LastWriteTime 
  if ($checkTS -gt $progressfileTS ) { $prog = load-progress; $progressfileTS = $checkTS}
  sleep 1
  $NewF = Get-Item "$journalpath\journal.20??-??-??T*.log" |select -Last 1
  if ($NewF.fullname -ne $F.FullName) {$linecount = 0; 
                                       $F = $newF
                                       $Status.comment = $F.name
                                       $status |convertto-json |set-content $statusfile
                                      }


  } # while GO

}  #JObScript


$MonProcess = get-process powershell -ErrorAction SilentlyContinue |where {$_.MainWindowTitle -eq "Colonisation Monitor"}
if ($MonProcess.hasExited -ne $false) {
        Start-Process powershell.exe -ArgumentList "-c","using namespace System.Windows.Forms;add-type -AssemblyName  System.Windows.Forms; . $monitorScript"
        } else {write-host Monitor is already running}



$Journal = Get-Item "$journalpath\journal.20??-??-??T*.log" |select -Last 1
$journalFullname = $Journal.fullname
jobscript

